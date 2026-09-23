package kv_tests

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"

import kv "../kv"

// A page-sized buffer aligned for casting to on-disk structs. A plain
// `[N]byte` only guarantees 1-byte alignment.
Page_Buf :: struct #align(16) {
	bytes: [kv.DEFAULT_PAGE_SIZE]byte,
}

// A temporary directory holding test databases, removed by `temp_dir_destroy`.
Temp_Dir :: struct {
	path: string,
}

// Fails the test immediately if the directory can't be created.
temp_dir_create :: proc(t: ^testing.T) -> Temp_Dir {
	base := string(posix.getenv("TMPDIR"))
	if base == "" {
		base = "/tmp"
	}
	template := strings.clone_to_cstring(fmt.tprintf("%s/kv_test_XXXXXX", strings.trim_right(base, "/")))
	defer delete(template)

	if posix.mkdtemp(([^]u8)(template)) == nil {
		testing.fail_now(t, "mkdtemp failed")
	}
	return Temp_Dir{path = strings.clone(string(template))}
}

temp_dir_file :: proc(dir: Temp_Dir, name: string) -> string {
	return fmt.tprintf("%s/%s", dir.path, name)
}

// Removes the files created in the directory, then the directory itself.
temp_dir_destroy :: proc(dir: ^Temp_Dir, files: ..string) {
	for name in files {
		cpath := strings.clone_to_cstring(temp_dir_file(dir^, name), context.temp_allocator)
		posix.unlink(cpath)
	}
	cdir := strings.clone_to_cstring(dir.path, context.temp_allocator)
	posix.rmdir(cdir)
	delete(dir.path)
	dir.path = ""
}
