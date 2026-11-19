#include "ARTrackerNative.h"
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <string.h>

uint32_t artn_copy_images(artn_image *out, uint32_t cap) {
    if (!out || cap == 0) return 0;
    uint32_t count = _dyld_image_count();
    uint32_t written = 0;

    for (uint32_t i = 0; i < count && written < cap; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        const char *name = _dyld_get_image_name(i);
        if (!mh || !name) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        uintptr_t text_start = 0;
        uintptr_t text_end = 0;
        uint8_t uuid[16] = {0};
        bool has_uuid = false;

        const uint8_t *cmd_ptr = NULL;
        uint32_t ncmds = 0;

        if (mh->magic == MH_MAGIC_64) {
            const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;
            cmd_ptr = (const uint8_t *)(mh64 + 1);
            ncmds = mh64->ncmds;
        } else if (mh->magic == MH_MAGIC) {
            cmd_ptr = (const uint8_t *)(mh + 1);
            ncmds = mh->ncmds;
        } else {
            continue;
        }

        for (uint32_t c = 0; c < ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)cmd_ptr;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                if (strncmp(seg->segname, SEG_TEXT, sizeof(seg->segname)) == 0) {
                    text_start = (uintptr_t)(seg->vmaddr + slide);
                    text_end = text_start + (uintptr_t)seg->vmsize;
                }
            } else if (lc->cmd == LC_SEGMENT) {
                const struct segment_command *seg = (const struct segment_command *)lc;
                if (strncmp(seg->segname, SEG_TEXT, sizeof(seg->segname)) == 0) {
                    text_start = (uintptr_t)(seg->vmaddr + slide);
                    text_end = text_start + (uintptr_t)seg->vmsize;
                }
            } else if (lc->cmd == LC_UUID) {
                const struct uuid_command *uc = (const struct uuid_command *)lc;
                memcpy(uuid, uc->uuid, 16);
                has_uuid = true;
            }
            cmd_ptr += lc->cmdsize;
        }

        if (text_start != 0 && text_end > text_start) {
            artn_image *img = &out[written++];
            img->load = (uintptr_t)mh;
            img->text_start = text_start;
            img->text_end = text_end;
            memcpy(img->uuid, uuid, 16);
            img->has_uuid = has_uuid;
            img->path = name;
        }
    }
    return written;
}
