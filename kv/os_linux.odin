package kv

import "core:sys/posix"

// Flushes the file's data, and the metadata needed to read it back (such as
// its size), to stable storage.
os_sync :: proc(fd: posix.FD) -> Error {
	if posix.fdatasync(fd) != .OK {
		return .Io
	}
	return .None
}
