#+build darwin
package kv_tests

import "core:c"
import "core:log"
import "core:sys/darwin"
import "core:time"

// The macOS side of platform_test.odin (KV-T-0019). See <sys/mman.h>; -1
// for advice macOS doesn't have.
MADV_RANDOM :: 1
MADV_DONTNEED :: 4
MADV_FREE :: 5
MADV_FREE_REUSABLE :: 7
MADV_FREE_REUSE :: 8
MADV_PAGEOUT :: -1

foreign import mach "system:System"

@(private = "file")
foreign mach {
	mach_vm_region :: proc(task: darwin.task_t, address: ^u64, size: ^u64, flavor: c.int, info: rawptr, count: ^u32, object_name: ^darwin.mach_port_t) -> darwin.Kern_Return ---
}

// <mach/vm_region.h>. Every field is 4-byte aligned, so the default layout
// matches the header's `#pragma pack(4)`.
@(private = "file")
VM_REGION_EXTENDED_INFO :: 13

@(private = "file")
Vm_Region_Extended_Info :: struct {
	protection:               i32,
	user_tag:                 u32,
	pages_resident:           u32,
	pages_shared_now_private: u32,
	pages_swapped_out:        u32,
	pages_dirtied:            u32,
	ref_count:                u32,
	shadow_depth:             u16,
	external_pager:           u8,
	share_mode:               u8,
	pages_reusable:           u32,
}

// <mach/task_info.h>, `task_vm_info` up to `phys_footprint` (revision 1).
// Past the first two 4-byte fields everything is 8 bytes and 8-aligned, so
// the default layout matches `#pragma pack(4)` here too.
@(private = "file")
TASK_VM_INFO :: 22

@(private = "file")
Task_Vm_Info :: struct {
	virtual_size:                 u64,
	region_count:                 i32,
	page_size:                    i32,
	resident_size:                u64,
	resident_size_peak:           u64,
	device:                       u64,
	device_peak:                  u64,
	internal:                     u64,
	internal_peak:                u64,
	external:                     u64,
	external_peak:                u64,
	reusable:                     u64,
	reusable_peak:                u64,
	purgeable_volatile_pmap:      u64,
	purgeable_volatile_resident:  u64,
	purgeable_volatile_virtual:   u64,
	compressed:                   u64,
	compressed_peak:              u64,
	compressed_lifetime:          u64,
	phys_footprint:               u64,
}

@(private = "file")
task_vm_info :: proc() -> (info: Task_Vm_Info) {
	count := u32(size_of(Task_Vm_Info) / 4)
	darwin.task_info(darwin.mach_task_self(), TASK_VM_INFO, darwin.task_info_t(&info), &count)
	return info
}

// The resident page count mach_vm_region reports for the regions starting
// in the range, in bytes. An eviction by remap splits the mapping into
// several regions, so they are summed.
@(private = "file")
region_resident :: proc(base: [^]byte, size: int) -> int {
	addr := u64(uintptr(base))
	end := addr + u64(size)
	pages := 0
	for addr < end {
		region_size: u64
		info: Vm_Region_Extended_Info
		count := u32(size_of(Vm_Region_Extended_Info) / 4)
		object: darwin.mach_port_t
		if mach_vm_region(darwin.mach_task_self(), &addr, &region_size, VM_REGION_EXTENDED_INFO, &info, &count, &object) != .Success {
			break
		}
		if addr >= end {
			break
		}
		pages += int(info.pages_resident)
		addr += region_size
	}
	return pages * int(darwin.vm_page_size)
}

// The figures for the range, and the process-wide ones. With a nil `base`,
// only the process-wide ones.
platform_residency :: proc(base: [^]byte, size: int) -> (r: Platform_Residency) {
	r = Platform_Residency{mincore = -1, present = -1, region = -1}
	if base != nil {
		ps := int(darwin.vm_page_size)
		vec := make([]u8, size / ps, context.temp_allocator)
		if mincore(base, c.size_t(size), raw_data(vec)) == 0 {
			r.mincore = 0
			for v in vec {
				// MINCORE_INCORE
				if v & 1 != 0 {
					r.mincore += ps
				}
			}
		}
		r.region = region_resident(base, size)
	}
	info := task_vm_info()
	r.rss = int(info.resident_size)
	r.footprint = int(info.phys_footprint)
	return r
}

// How long the platform's own sources take over the range.
platform_source_costs :: proc(base: [^]byte, size: int) {
	start := time.tick_now()
	for _ in 0 ..< 10 {
		region_resident(base, size)
	}
	log.infof("mach_vm_region over the range: %.1f µs per call", time.duration_microseconds(time.tick_since(start)) / 10)
	start = time.tick_now()
	for _ in 0 ..< 10 {
		task_vm_info()
	}
	log.infof("task_info(TASK_VM_INFO): %.1f µs per call", time.duration_microseconds(time.tick_since(start)) / 10)
}
