package kv_tests

import "core:hash/xxhash"
import "core:mem"
import "core:testing"

import kv "../kv"

sample_meta :: proc() -> kv.Meta {
	return kv.Meta {
		magic     = kv.MAGIC,
		version   = kv.VERSION,
		page_size = kv.DEFAULT_PAGE_SIZE,
		txn_id    = 7,
		root      = 12,
		depth     = 2,
		entries   = 1000,
		last_pgno = 40,
	}
}

@(test)
test_meta_checksum_covers_fields_before_checksum :: proc(t: ^testing.T) {
	m := sample_meta()
	sum := kv.meta_checksum(&m)

	expected := u64(xxhash.XXH64(mem.byte_slice(&m, offset_of(kv.Meta, checksum))))
	testing.expect_value(t, sum, expected)

	// The stored checksum itself is not part of the hashed bytes.
	m.checksum = u64le(sum)
	testing.expect_value(t, kv.meta_checksum(&m), sum)

	// Any change to a covered field changes the checksum.
	m.txn_id += 1
	testing.expect(t, kv.meta_checksum(&m) != sum, "txn_id change not detected")
	m.txn_id -= 1

	m.freelist_count = 1
	testing.expect(t, kv.meta_checksum(&m) != sum, "freelist_count change not detected")
	m.freelist_count = 0

	testing.expect_value(t, kv.meta_checksum(&m), sum)
}

@(test)
test_magic_bytes :: proc(t: ^testing.T) {
	m := sample_meta()
	bytes := mem.byte_slice(&m.magic, size_of(m.magic))
	testing.expect_value(t, string(bytes), "ODKV")
}

@(test)
test_page_accessors :: proc(t: ^testing.T) {
	buf: Page_Buf
	page := buf.bytes[:]

	h := kv.page_header(page)
	h.pgno = 1
	h.flags = kv.PAGE_META
	m := kv.page_meta(page)
	m^ = sample_meta()

	testing.expect_value(t, uintptr(rawptr(m)) - uintptr(raw_data(page)), uintptr(kv.META_OFFSET))

	// The union in the header: lower/upper and overflow_count share bytes 12..16.
	h.lower = 0x1111
	h.upper = 0x2222
	testing.expect_value(t, h.overflow_count, 0x2222_1111)
}

@(test)
test_page_size_valid :: proc(t: ^testing.T) {
	for size in ([]int{4096, 8192, 16384, 32768}) {
		testing.expectf(t, kv.page_size_valid(size), "%d should be valid", size)
	}
	for size in ([]int{0, 512, 2048, 4095, 6144, 65536}) {
		testing.expectf(t, !kv.page_size_valid(size), "%d should be invalid", size)
	}
}
