package kv

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:sync"
import "core:sys/posix"

// Address space reserved for the map when `Options.map_size` is 0. It only
// limits how large the database can grow; it isn't memory in use.
DEFAULT_MAP_SIZE :: 1 << 30

// The map size is rounded up to a multiple of this, which covers every valid
// page size and the OS page size on all supported platforms.
MAP_SIZE_GRANULE :: 64 * 1024

Options :: struct {
	// Bytes of address space to reserve; 0 means DEFAULT_MAP_SIZE. It is
	// enlarged if the existing file is bigger.
	map_size:  int,
	// Page size for a new database; 0 means DEFAULT_PAGE_SIZE. An existing
	// database keeps the page size it was created with.
	page_size: int,
}

// The committed state that a transaction starts from.
Snapshot :: struct {
	txn_id:         Txn_Id,
	root:           Pgno,
	depth:          u32,
	last_pgno:      Pgno,
	entries:        u64,
	// The free-list run and its number of records, or 0 and 0.
	freelist_pgno:  Pgno,
	freelist_count: u64,
}

// Initial capacity of the reader table. Readers mostly share the latest
// snapshot, so a few slots cover the usual case.
READER_TABLE_CAPACITY :: 16

// One entry of the reader table: `count` live read transactions hold the
// snapshot `txn_id`. Slots with a count of 0 are removed.
Reader_Slot :: struct {
	txn_id: Txn_Id,
	count:  int,
}

/*
Figures about an Env, as returned by env_stats. They are read together
under one lock, so they describe one instant, but they can be stale as
soon as env_stats returns. A write transaction in progress shows in none of
them until it commits.

Step 6 (the memory budget) extends this with the resident estimate, dirty
pages, spills and evictions; code that builds a Stats should name its
fields.
*/
Stats :: struct {
	// The last page of the latest committed snapshot.
	last_pgno:     Pgno,
	// Pages in the file. The file grows ahead of last_pgno in steps (see
	// FILE_GROWTH_MIN), and never shrinks.
	file_pages:    int,
	// Free pages that a write transaction beginning now may reuse. The
	// release at txn_begin moves pending pages here, so after readers end
	// this count only catches up when the next write transaction begins.
	free_ready:    int,
	// Free pages still waiting for older snapshots to end (KV-I-0002 REQ-002).
	free_pending:  int,
	// Live read transactions.
	readers:       int,
	// The oldest snapshot a live read transaction holds, or 0 if none does.
	oldest_reader: Txn_Id,
}

Env :: struct {
	fd:             posix.FD,
	map_base:       [^]byte,
	map_size:       int,
	page_size:      int,
	// Current size of the file in bytes. Only changed by the writer.
	file_size:      i64,
	// The last committed state. Guarded by snapshot_mutex.
	snapshot:       Snapshot,
	snapshot_mutex: sync.Mutex,
	// Snapshots held by live read transactions, sorted by txn_id with one
	// slot per snapshot, so readers[0] is the oldest. Guarded by
	// snapshot_mutex, and allocated with `allocator`.
	readers:        [dynamic]Reader_Slot,
	// Held for the whole lifetime of a write transaction.
	writer_mutex:   sync.Mutex,
	// The free list of the last commit. Owned by the writer: only used with
	// writer_mutex held, and replaced by a commit once it is durable.
	free:           Free_State,
	// The writer's figures for env_stats: file_pages, free_ready and
	// free_pending, copied from file_size and `free` whenever the writer
	// changes those. Guarded by snapshot_mutex, so env_stats never waits
	// for a write transaction to end. The other fields are unused.
	stats:          Stats,
	// Number of transactions not yet ended, updated atomically. Checked by
	// env_close in debug builds.
	active_txns:    int,
	allocator:      runtime.Allocator,
}

// Opens the database at `path`, creating it if the file doesn't exist or is
// empty. The file stays exclusively locked until env_close.
env_open :: proc(path: string, options := Options{}, allocator := context.allocator) -> (env: ^Env, err: Error) {
	page_size := options.page_size if options.page_size != 0 else DEFAULT_PAGE_SIZE
	if !page_size_valid(page_size) {
		return nil, .Invalid_Argument
	}
	map_size := options.map_size if options.map_size > 0 else DEFAULT_MAP_SIZE

	fd := os_open(path, create = true) or_return
	defer if err != .None {
		os_close(fd)
	}

	file_size := os_file_size(fd) or_return
	if file_size == 0 {
		init_meta_pages(fd, page_size) or_return
		file_size = 2 * i64(page_size)
	}

	// The map must cover the whole file.
	map_size = mem.align_forward_int(max(map_size, int(file_size)), MAP_SIZE_GRANULE)
	base := os_map_reserve(fd, map_size) or_return
	defer if err != .None {
		os_unmap(base, map_size)
	}
	os_advise_random(base, map_size) or_return

	meta, meta_page_size, found := meta_choose(base[:file_size])
	if !found {
		return nil, .Corrupted
	}
	snapshot := snapshot_from_meta(meta)
	free_state := freelist_load(base, meta_page_size, snapshot, allocator) or_return
	defer if err != .None {
		free_state_destroy(&free_state)
	}

	readers, readers_err := make([dynamic]Reader_Slot, 0, READER_TABLE_CAPACITY, allocator)
	if readers_err != nil {
		return nil, .Out_Of_Memory
	}
	env, _ = new(Env, allocator)
	if env == nil {
		delete(readers)
		return nil, .Out_Of_Memory
	}
	env^ = Env {
		fd        = fd,
		map_base  = base,
		map_size  = map_size,
		page_size = meta_page_size,
		file_size = file_size,
		snapshot  = snapshot,
		readers   = readers,
		free      = free_state,
		allocator = allocator,
	}
	env.stats.file_pages = int(file_size) / meta_page_size
	stats_update_free(env)
	return env, .None
}

// Unmaps the database and closes the file, releasing its lock. All
// transactions must have ended.
env_close :: proc(env: ^Env) {
	when ODIN_DEBUG {
		assert(sync.atomic_load(&env.active_txns) == 0, "env_close with active transactions")
		assert(len(env.readers) == 0, "env_close with registered readers")
	}
	os_unmap(env.map_base, env.map_size)
	os_close(env.fd)
	delete(env.readers)
	free_state_destroy(&env.free)
	free(env, env.allocator)
}

// Returns the last committed state.
env_snapshot :: proc(env: ^Env) -> Snapshot {
	sync.mutex_lock(&env.snapshot_mutex)
	defer sync.mutex_unlock(&env.snapshot_mutex)
	return env.snapshot
}

/*
Returns figures about the environment (see Stats). Safe to call from any
thread, including one with a transaction open: it only takes snapshot_mutex,
briefly, and never waits for a write transaction to end. The free-page
counts are those of the last commit, plus any release done since by a
beginning write transaction; a write transaction in progress doesn't change
them until it commits.
*/
env_stats :: proc(env: ^Env) -> Stats {
	sync.mutex_lock(&env.snapshot_mutex)
	defer sync.mutex_unlock(&env.snapshot_mutex)
	stats := env.stats
	stats.last_pgno = env.snapshot.last_pgno
	for slot in env.readers {
		stats.readers += slot.count
	}
	stats.oldest_reader, _ = oldest_reader(env)
	return stats
}

// Copies the sizes of Env.free into Env.stats. The caller is the writer, or
// env_open; it holds writer_mutex but not snapshot_mutex.
@(private)
stats_update_free :: proc(env: ^Env) {
	sync.mutex_lock(&env.snapshot_mutex)
	env.stats.free_ready = len(env.free.ready)
	env.stats.free_pending = len(env.free.pending)
	sync.mutex_unlock(&env.snapshot_mutex)
}

// Returns the oldest snapshot held by a live read transaction, or false if
// there are none. The answer can be stale as soon as it returns; it's meant
// for tests and statistics.
env_oldest_reader :: proc(env: ^Env) -> (txn_id: Txn_Id, ok: bool) {
	sync.mutex_lock(&env.snapshot_mutex)
	defer sync.mutex_unlock(&env.snapshot_mutex)
	return oldest_reader(env)
}

// Returns the oldest snapshot in the reader table. The caller holds
// snapshot_mutex.
@(private)
oldest_reader :: proc(env: ^Env) -> (txn_id: Txn_Id, ok: bool) {
	if len(env.readers) == 0 {
		return 0, false
	}
	return env.readers[0].txn_id, true
}

// Registers a read transaction on `txn_id`, the current snapshot. The caller
// holds snapshot_mutex. Snapshots are published in increasing order, so the
// new reader either joins the last slot or appends one; the table only
// allocates when it outgrows its largest size so far.
@(private)
reader_register :: proc(env: ^Env, txn_id: Txn_Id) -> Error {
	if n := len(env.readers); n > 0 {
		last := &env.readers[n - 1]
		assert(last.txn_id <= txn_id, "reader snapshot older than a registered one")
		if last.txn_id == txn_id {
			last.count += 1
			return .None
		}
	}
	if _, err := append(&env.readers, Reader_Slot{txn_id, 1}); err != nil {
		return .Out_Of_Memory
	}
	return .None
}

// Deregisters a read transaction on `txn_id`, removing its slot when no
// reader is left on it. The caller holds snapshot_mutex. The key is the
// snapshot rather than a slot index, because indices shift on removal.
@(private)
reader_deregister :: proc(env: ^Env, txn_id: Txn_Id) {
	i, found := slice.binary_search_by(env.readers[:], txn_id, proc(slot: Reader_Slot, key: Txn_Id) -> slice.Ordering {
		return slice.cmp(slot.txn_id, key)
	})
	assert(found, "deregistering a reader that isn't registered")
	env.readers[i].count -= 1
	if env.readers[i].count == 0 {
		ordered_remove(&env.readers, i)
	}
}

// Writes `meta` to meta page `slot` (0 or 1), filling in the page header and
// checksum. Only the header and meta are written; the rest of the page is
// left as is.
meta_write :: proc(env: ^Env, slot: int, meta: Meta) -> Error {
	return meta_write_fd(env.fd, env.page_size, slot, meta)
}

@(private = "file")
Meta_Page_Prefix :: struct {
	header: Page_Header,
	meta:   Meta,
}

#assert(offset_of(Meta_Page_Prefix, meta) == META_OFFSET)

@(private = "file")
meta_write_fd :: proc(fd: posix.FD, page_size: int, slot: int, meta: Meta) -> Error {
	assert(slot == 0 || slot == 1)
	prefix := Meta_Page_Prefix {
		header = {pgno = u64le(slot), flags = PAGE_META},
		meta   = meta,
	}
	prefix.meta.checksum = u64le(meta_checksum(&prefix.meta))
	return os_pwrite(fd, mem.ptr_to_bytes(&prefix), i64(slot) * i64(page_size))
}

// Writes the two meta pages of an empty database. Both describe the same
// empty tree at txn 0, so either one is enough to open the file.
@(private = "file")
init_meta_pages :: proc(fd: posix.FD, page_size: int) -> Error {
	os_truncate(fd, 2 * i64(page_size)) or_return
	meta := Meta {
		magic     = MAGIC,
		version   = VERSION,
		page_size = u32le(page_size),
		last_pgno = 1,
	}
	meta_write_fd(fd, page_size, 0, meta) or_return
	meta_write_fd(fd, page_size, 1, meta) or_return
	return os_sync(fd)
}

// Picks the valid meta page with the highest txn_id, preferring page 0 on a
// tie. `file` is the mapped file, so nothing past its end is touched.
@(private = "file")
meta_choose :: proc(file: []byte) -> (meta: Meta, page_size: int, found: bool) {
	// Page 0 is at offset 0 whatever the page size, and a valid meta page
	// tells us where page 1 is. If page 0 is damaged, try every page size.
	meta0, ok0 := meta_read(file, 0, -1)
	page_sizes: []int = {int(meta0.page_size)} if ok0 else {4096, 8192, 16384, 32768}

	for size in page_sizes {
		meta1, ok1 := meta_read(file, 1, size)
		if !ok1 {
			continue
		}
		if ok0 && meta0.txn_id >= meta1.txn_id {
			return meta0, size, true
		}
		return meta1, size, true
	}
	if ok0 {
		return meta0, int(meta0.page_size), true
	}
	return {}, 0, false
}

// Reads and validates meta page `slot`. With `page_size` of -1, the page size
// recorded in the meta itself is used (only meaningful for slot 0).
@(private = "file")
meta_read :: proc(file: []byte, slot: int, page_size: int) -> (meta: Meta, ok: bool) {
	prefix_size := size_of(Meta_Page_Prefix)
	offset := slot * page_size if slot > 0 else 0
	if offset + prefix_size > len(file) {
		return {}, false
	}

	// Copy before validating, so the checks and the caller see the same bytes.
	prefix: Meta_Page_Prefix
	mem.copy_non_overlapping(&prefix, raw_data(file[offset:]), prefix_size)
	meta = prefix.meta

	if meta.magic != MAGIC || meta.version != VERSION {
		return {}, false
	}
	if u64(meta.checksum) != meta_checksum(&meta) {
		return {}, false
	}
	size := int(meta.page_size)
	if !page_size_valid(size) || (page_size != -1 && size != page_size) {
		return {}, false
	}
	if prefix.header.pgno != u64le(slot) || prefix.header.flags & PAGE_META == 0 {
		return {}, false
	}
	// The whole meta page, and every page the meta refers to, must be in the
	// file. Compare page counts so a huge last_pgno can't overflow.
	if offset + size > len(file) || u64(meta.last_pgno) >= u64(len(file) / size) {
		return {}, false
	}
	if meta.last_pgno < 1 || meta.root > meta.last_pgno || (meta.root == 0) != (meta.depth == 0) {
		return {}, false
	}
	// The free-list run too. Bounding the count by the file first keeps the
	// size computation from overflowing; the list itself is checked when it
	// is loaded.
	if meta.freelist_pgno != 0 {
		if meta.freelist_pgno < 2 || u64(meta.freelist_count) > u64(len(file) / size_of(Free_Record)) {
			return {}, false
		}
		run_pages := freelist_run_pages(size, int(meta.freelist_count))
		if u64(meta.freelist_pgno) + u64(run_pages) - 1 > u64(meta.last_pgno) {
			return {}, false
		}
	}
	return meta, true
}

@(private = "file")
snapshot_from_meta :: proc(meta: Meta) -> Snapshot {
	return Snapshot {
		txn_id         = Txn_Id(meta.txn_id),
		root           = Pgno(meta.root),
		depth          = u32(meta.depth),
		last_pgno      = Pgno(meta.last_pgno),
		entries        = u64(meta.entries),
		freelist_pgno  = Pgno(meta.freelist_pgno),
		freelist_count = u64(meta.freelist_count),
	}
}
