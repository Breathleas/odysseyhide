
//
//  patchfinder64.c
//  extra_recipe
//
//  Created by xerub on 06/06/2017.
//  Copyright © 2017 xerub. All rights reserved.
//

#import <assert.h>
#import <stdint.h>
#import <string.h>
#import <stdbool.h>
#import <mach-o/fat.h>

#import "kernel_utils.h"

extern uint32_t KASLR_Slide;

typedef unsigned long long addr_t;

#define IS64(image) (*(uint8_t *)(image) & 1)

#define MACHO(p) ((*(unsigned int *)(p) & ~1) == 0xfeedface)

/* generic stuff *************************************************************/

#define UCHAR_MAX 255

static unsigned char *
Boyermoore_horspool_memmem(const unsigned char* haystack, size_t hlen,
                           const unsigned char* needle,   size_t nlen)
{
    size_t last, scan = 0;
    size_t bad_char_skip[UCHAR_MAX + 1]; /* Officially called:
                                          * bad character shift */
    
    /* Sanity checks on the parameters */
    if (nlen <= 0 || !haystack || !needle)
        return NULL;
    
    /* ---- Preprocess ---- */
    /* Initialize the table to default value */
    /* When a character is encountered that does not occur
     * in the needle, we can safely skip ahead for the whole
     * length of the needle.
     */
    for (scan = 0; scan <= UCHAR_MAX; scan = scan + 1)
        bad_char_skip[scan] = nlen;
    
    /* C arrays have the first byte at [0], therefore:
     * [nlen - 1] is the last byte of the array. */
    last = nlen - 1;
    
    /* Then populate it with the analysis of the needle */
    for (scan = 0; scan < last; scan = scan + 1)
        bad_char_skip[needle[scan]] = last - scan;
    
    /* ---- Do the matching ---- */
    
    /* Search the haystack, while the needle can still be within it. */
    while (hlen >= nlen)
    {
        /* scan from the end of the needle */
        for (scan = last; haystack[scan] == needle[scan]; scan = scan - 1)
            if (scan == 0) /* If the first byte matches, we've found it. */
                return (void *)haystack;
        
        /* otherwise, we need to skip some bytes and start again.
         Note that here we are getting the skip value based on the last byte
         of needle, no matter where we didn't match. So if needle is: "abcd"
         then we are skipping based on 'd' and that value will be 4, and
         for "abcdd" we again skip on 'd' but the value will be only 1.
         The alternative of pretending that the mismatched character was
         the last character is slower in the normal case (E.g. finding
         "abcd" in "...azcd..." gives 4 by using 'd' but only
         4-2==2 using 'z'. */
        hlen     -= bad_char_skip[haystack[last]];
        haystack += bad_char_skip[haystack[last]];
    }
    
    return NULL;
}

/* disassembler **************************************************************/

static int HighestSetBit(int N, uint32_t imm)
{
    int i;
    for (i = N - 1; i >= 0; i--) {
        if (imm & (1 << i)) {
            return i;
        }
    }
    return -1;
}

static uint64_t ZeroExtendOnes(unsigned M, unsigned N)    // zero extend M ones to N width
{
    (void)N;
    return ((uint64_t)1 << M) - 1;
}

static uint64_t RORZeroExtendOnes(unsigned M, unsigned N, unsigned R)
{
    uint64_t val = ZeroExtendOnes(M, N);
    if (R == 0) {
        return val;
    }
    return ((val >> R) & (((uint64_t)1 << (N - R)) - 1)) | ((val & (((uint64_t)1 << R) - 1)) << (N - R));
}

static uint64_t Replicate(uint64_t val, unsigned bits)
{
    uint64_t ret = val;
    unsigned shift;
    for (shift = bits; shift < 64; shift += bits) {    // XXX actually, it is either 32 or 64
        ret |= (val << shift);
    }
    return ret;
}

static int DecodeBitMasks(unsigned immN, unsigned imms, unsigned immr, int immediate, uint64_t *newval)
{
    unsigned levels, S, R, esize;
    int len = HighestSetBit(7, (immN << 6) | (~imms & 0x3F));
    if (len < 1) {
        return -1;
    }
    levels = ZeroExtendOnes(len, 6);
    if (immediate && (imms & levels) == levels) {
        return -1;
    }
    S = imms & levels;
    R = immr & levels;
    esize = 1 << len;
    *newval = Replicate(RORZeroExtendOnes(S + 1, esize, R), esize);
    return 0;
}

static int DecodeMov(uint32_t opcode, uint64_t total, int first, uint64_t *newval)
{
    unsigned o = (opcode >> 29) & 3;
    unsigned k = (opcode >> 23) & 0x3F;
    unsigned rn, rd;
    uint64_t i;
    
    if (k == 0x24 && o == 1) {            // MOV (bitmask imm) <=> ORR (immediate)
        unsigned s = (opcode >> 31) & 1;
        unsigned N = (opcode >> 22) & 1;
        if (s == 0 && N != 0) {
            return -1;
        }
        rn = (opcode >> 5) & 0x1F;
        if (rn == 31) {
            unsigned imms = (opcode >> 10) & 0x3F;
            unsigned immr = (opcode >> 16) & 0x3F;
            return DecodeBitMasks(N, imms, immr, 1, newval);
        }
    } else if (k == 0x25) {                // MOVN/MOVZ/MOVK
        unsigned s = (opcode >> 31) & 1;
        unsigned h = (opcode >> 21) & 3;
        if (s == 0 && h > 1) {
            return -1;
        }
        i = (opcode >> 5) & 0xFFFF;
        h *= 16;
        i <<= h;
        if (o == 0) {                // MOVN
            *newval = ~i;
            return 0;
        } else if (o == 2) {            // MOVZ
            *newval = i;
            return 0;
        } else if (o == 3 && !first) {        // MOVK
            *newval = (total & ~((uint64_t)0xFFFF << h)) | i;
            return 0;
        }
    } else if ((k | 1) == 0x23 && !first) {        // ADD (immediate)
        unsigned h = (opcode >> 22) & 3;
        if (h > 1) {
            return -1;
        }
        rd = opcode & 0x1F;
        rn = (opcode >> 5) & 0x1F;
        if (rd != rn) {
            return -1;
        }
        i = (opcode >> 10) & 0xFFF;
        h *= 12;
        i <<= h;
        if (o & 2) {                // SUB
            *newval = total - i;
            return 0;
        } else {                // ADD
            *newval = total + i;
            return 0;
        }
    }
    
    return -1;
}

/* patchfinder ***************************************************************/

static addr_t
Step64(const uint8_t *buf, addr_t start, size_t length, uint32_t what, uint32_t mask)
{
    addr_t end = start + length;
    while (start < end) {
        uint32_t x = *(uint32_t *)(buf + start);
        if ((x & mask) == what) {
            return start;
        }
        start += 4;
    }
    return 0;
}

// str8 = Step64_back(Kernel, ref, ref - bof, INSN_STR8);
static addr_t
Step64_back(const uint8_t *buf, addr_t start, size_t length, uint32_t what, uint32_t mask)
{
    addr_t end = start - length;
    while (start >= end) {
        uint32_t x = *(uint32_t *)(buf + start);
        if ((x & mask) == what) {
            return start;
        }
        start -= 4;
    }
    return 0;
}

// Finds start of function
static addr_t
BOF64(const uint8_t *buf, addr_t start, addr_t where)
{
    extern addr_t PPLText_size;
    if (PPLText_size) {
        for (; where >= start; where -= 4) {
            uint32_t op = *(uint32_t *)(buf + where);
            if (op == 0xD503237F) {
                return where;
            }
        }
        return 0;
    }
    
    for (; where >= start; where -= 4) {
        uint32_t op = *(uint32_t *)(buf + where);
        
        if ((op & 0xFFC003FF) == 0x910003FD) {
            unsigned delta = (op >> 10) & 0xFFF;
            //printf("%x: ADD X29, SP, #0x%x\n", where, delta);
            if ((delta & 0xF) == 0) {
                addr_t prev = where - ((delta >> 4) + 1) * 4;
                uint32_t au = *(uint32_t *)(buf + prev);
                if ((au & 0xFFC003E0) == 0xA98003E0) {
                    //printf("%x: STP x, y, [SP,#-imm]!\n", prev);
                    if (*(uint32_t *)(buf + prev - 4) == 0xd503237f) return prev - 4;
                    return prev;
                }
                // try something else
                while (where > start) {
                    where -= 4;
                    au = *(uint32_t *)(buf + where);
                    // SUB SP, SP, #imm
                    if ((au & 0xFFC003FF) == 0xD10003FF && ((au >> 10) & 0xFFF) == delta + 0x10) {
                        if (*(uint32_t *)(buf + where - 4) == 0xd503237f) return where - 4;
                        return where;
                    }
                    // STP x, y, [SP,#imm]
                    if ((au & 0xFFC003E0) != 0xA90003E0) {
                        where += 4;
                        break;
                    }
                }
            }
        }
    }
    return 0;
}

static addr_t
Follow_call64(const uint8_t *buf, addr_t call)
{
    long long w;
    w = *(uint32_t *)(buf + call) & 0x3FFFFFF;
    w <<= 64 - 26;
    w >>= 64 - 26 - 2;
    return call + w;
}

static addr_t
XREF64(const uint8_t *buf, addr_t start, addr_t end, addr_t what)
{
    addr_t i;
    uint64_t value[32];
    
    memset(value, 0, sizeof(value));
    
    end &= ~3;
    for (i = start & ~3; i < end; i += 4) {
        uint32_t op = *(uint32_t *)(buf + i);
        unsigned reg = op & 0x1F;
        if ((op & 0x9F000000) == 0x90000000) {
            signed adr = ((op & 0x60000000) >> 18) | ((op & 0xFFFFE0) << 8);
            //printf("%llx: ADRP X%d, 0x%llx\n", i, reg, ((long long)adr << 1) + (i & ~0xFFF));
            value[reg] = ((long long)adr << 1) + (i & ~0xFFF);
            /*} else if ((op & 0xFFE0FFE0) == 0xAA0003E0) {
             unsigned rd = op & 0x1F;
             unsigned rm = (op >> 16) & 0x1F;
             //printf("%llx: MOV X%d, X%d\n", i, rd, rm);
             value[rd] = value[rm];*/
        } else if ((op & 0xFF000000) == 0x91000000) {
            unsigned rn = (op >> 5) & 0x1F;
            unsigned shift = (op >> 22) & 3;
            unsigned imm = (op >> 10) & 0xFFF;
            if (shift == 1) {
                imm <<= 12;
            } else {
                //assert(shift == 0);
                if (shift > 1) continue;
            }
            //printf("%llx: ADD X%d, X%d, 0x%x\n", i, reg, rn, imm);
            value[reg] = value[rn] + imm;
        } else if ((op & 0xF9C00000) == 0xF9400000) {
            unsigned rn = (op >> 5) & 0x1F;
            unsigned imm = ((op >> 10) & 0xFFF) << 3;
            //printf("%llx: LDR X%d, [X%d, 0x%x]\n", i, reg, rn, imm);
            if (!imm) continue;            // XXX not counted as true xref
            value[reg] = value[rn] + imm;    // XXX address, not actual value
            /*} else if ((op & 0xF9C00000) == 0xF9000000) {
             unsigned rn = (op >> 5) & 0x1F;
             unsigned imm = ((op >> 10) & 0xFFF) << 3;
             //printf("%llx: STR X%d, [X%d, 0x%x]\n", i, reg, rn, imm);
             if (!imm) continue;            // XXX not counted as true xref
             value[rn] = value[rn] + imm;    // XXX address, not actual value*/
        } else if ((op & 0x9F000000) == 0x10000000) {
            signed adr = ((op & 0x60000000) >> 18) | ((op & 0xFFFFE0) << 8);
            //printf("%llx: ADR X%d, 0x%llx\n", i, reg, ((long long)adr >> 11) + i);
            value[reg] = ((long long)adr >> 11) + i;
        } else if ((op & 0xFF000000) == 0x58000000) {
            unsigned adr = (op & 0xFFFFE0) >> 3;
            //printf("%llx: LDR X%d, =0x%llx\n", i, reg, adr + i);
            value[reg] = adr + i;        // XXX address, not actual value
        }
        else if ((op & 0xFC000000) == 0x94000000) {
            if (Follow_call64(buf, i) == what) {
                return i;
            }
        }
        else if ((op & 0xFC000000) == 0x14000000) {
            if (Follow_call64(buf, i) == what) {
                return i;
            }
        }
        else if ((op & 0x7F000000) == 0x37000000) {
            uint64_t addr = i + 4 * ((op & 0x7FFE0) >> 5);
            if (addr == what) {
                return i;
            }
        }
        if (value[reg] == what) {
            return i;
        }
    }
    return 0;
}

static addr_t
Calc64(const uint8_t *buf, addr_t start, addr_t end, int which)
{
    addr_t i;
    uint64_t value[32];
    
    memset(value, 0, sizeof(value));
    
    end &= ~3;
    for (i = start & ~3; i < end; i += 4) {
        uint32_t op = *(uint32_t *)(buf + i);
        unsigned reg = op & 0x1F;
        if ((op & 0x9F000000) == 0x90000000) {
            signed adr = ((op & 0x60000000) >> 18) | ((op & 0xFFFFE0) << 8);
            //printf("%llx: ADRP X%d, 0x%llx\n", i, reg, ((long long)adr << 1) + (i & ~0xFFF));
            value[reg] = ((long long)adr << 1) + (i & ~0xFFF);
            /*} else if ((op & 0xFFE0FFE0) == 0xAA0003E0) {
             unsigned rd = op & 0x1F;
             unsigned rm = (op >> 16) & 0x1F;
             //printf("%llx: MOV X%d, X%d\n", i, rd, rm);
             value[rd] = value[rm];*/
        } else if ((op & 0xFF000000) == 0x91000000) {
            unsigned rn = (op >> 5) & 0x1F;
            unsigned shift = (op >> 22) & 3;
            unsigned imm = (op >> 10) & 0xFFF;
            if (shift == 1) {
                imm <<= 12;
            } else {
                //assert(shift == 0);
                if (shift > 1) continue;
            }
            //printf("%llx: ADD X%d, X%d, 0x%x\n", i, reg, rn, imm);
            value[reg] = value[rn] + imm;
        } else if ((op & 0xFF000000) == 0xd2000000) {
            unsigned val = (op & 0x1fffe0) >> 5; // idk if this is really correct but works for our purpose
            value[reg] = val;
        }
        else if ((op & 0xF9C00000) == 0xF9400000) {
            unsigned rn = (op >> 5) & 0x1F;
            unsigned imm = ((op >> 10) & 0xFFF) << 3;
            //printf("%llx: LDR X%d, [X%d, 0x%x]\n", i, reg, rn, imm);
            if (!imm) continue;            // XXX not counted as true xref
            value[reg] = value[rn] + imm;    // XXX address, not actual value
        } else if ((op & 0xF9C00000) == 0xb9400000) { // 32bit
            unsigned rn = (op >> 5) & 0x1F;
            unsigned imm = ((op >> 10) & 0xFFF) << 2;
            if (!imm) continue;            // XXX not counted as true xref
            value[reg] = value[rn] + imm;    // XXX address, not actual value
        } else if ((op & 0xF9C00000) == 0xF9000000) {
            unsigned rn = (op >> 5) & 0x1F;
            unsigned imm = ((op >> 10) & 0xFFF) << 3;
            //printf("%llx: STR X%d, [X%d, 0x%x]\n", i, reg, rn, imm);
            if (!imm) continue;            // XXX not counted as true xref
            value[rn] = value[rn] + imm;    // XXX address, not actual value
        } else if ((op & 0x9F000000) == 0x10000000) {
            signed adr = ((op & 0x60000000) >> 18) | ((op & 0xFFFFE0) << 8);
            //printf("%llx: ADR X%d, 0x%llx\n", i, reg, ((long long)adr >> 11) + i);
            value[reg] = ((long long)adr >> 11) + i;
        } else if ((op & 0xFF000000) == 0x58000000) {
            unsigned adr = (op & 0xFFFFE0) >> 3;
            //printf("%llx: LDR X%d, =0x%llx\n", i, reg, adr + i);
            value[reg] = adr + i;        // XXX address, not actual value
        }
    }
    return value[which];
}

static addr_t
Calc64mov(const uint8_t *buf, addr_t start, addr_t end, int which)
{
    addr_t i;
    uint64_t value[32];
    
    memset(value, 0, sizeof(value));
    
    end &= ~3;
    for (i = start & ~3; i < end; i += 4) {
        uint32_t op = *(uint32_t *)(buf + i);
        unsigned reg = op & 0x1F;
        uint64_t newval;
        int rv = DecodeMov(op, value[reg], 0, &newval);
        if (rv == 0) {
            if (((op >> 31) & 1) == 0) {
                newval &= 0xFFFFFFFF;
            }
            value[reg] = newval;
        }
    }
    return value[which];
}

static addr_t
Find_call64(const uint8_t *buf, addr_t start, size_t length)
{
    return Step64(buf, start, length, 0x94000000, 0xFC000000);
}

static addr_t
Follow_cbz(const uint8_t *buf, addr_t cbz)
{
    return cbz + ((*(int *)(buf + cbz) & 0x3FFFFE0) << 10 >> 13);
}

/* kernel iOS10 **************************************************************/

#import <fcntl.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <mach-o/loader.h>

static uint8_t *Kernel = NULL;
static size_t Kernel_size = 0;

static addr_t XNUCore_Base = 0;
static addr_t XNUCore_Size = 0;
static addr_t Prelink_Base = 0;
static addr_t Prelink_Size = 0;
static addr_t CString_base = 0;
static addr_t CString_size = 0;
static addr_t PString_base = 0;
static addr_t PString_size = 0;
static addr_t OSLog_base = 0;
static addr_t OSLog_size = 0;
static addr_t Data_base = 0;
static addr_t Data_size = 0;
static addr_t Data_const_base = 0;
static addr_t Data_const_size = 0;
addr_t PPLText_base = 0;
addr_t PPLText_size = 0;

static addr_t KernDumpBase = -1;
static addr_t Kernel_entry = 0;
static void *Kernel_mh = 0;
static addr_t Kernel_delta = 0;

static uint32_t arch_off = 0;

int
InitPatchfinder(addr_t base, const char *filename)
{
    size_t rv;
    uint8_t buf[0x4000];
    unsigned i, j;
    const struct mach_header *hdr = (struct mach_header *)buf;
    const uint8_t *q;
    addr_t min = -1;
    addr_t max = 0;
    int is64 = 0;
    
    int fd = open(filename, O_RDONLY);
    if (fd < 0) {
        return -1;
    }

    uint32_t magic;
    read(fd, &magic, 4);
    lseek(fd, 0, SEEK_SET);
    if (magic == 0xbebafeca) {
        struct fat_header fat;
        lseek(fd, sizeof(fat), SEEK_SET);
        struct fat_arch_64 arch;
        read(fd, &arch, sizeof(arch));
        arch_off = ntohl(arch.offset);
        lseek(fd, arch_off, SEEK_SET); // kerneldec gives a FAT binary for some reason
    }
    
    rv = read(fd, buf, sizeof(buf));
    if (rv != sizeof(buf)) {
        close(fd);
        return -1;
    }
    
    if (!MACHO(buf)) {
        close(fd);
        return -1;
    }
    
    if (IS64(buf)) {
        is64 = 4;
    }
    
    q = buf + sizeof(struct mach_header) + is64;
    for (i = 0; i < hdr->ncmds; i++) {
        const struct load_command *cmd = (struct load_command *)q;
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (struct segment_command_64 *)q;
            if (min > seg->vmaddr) {
                min = seg->vmaddr;
            }
            if (max < seg->vmaddr + seg->vmsize) {
                max = seg->vmaddr + seg->vmsize;
            }
            if (!strcmp(seg->segname, "__TEXT_EXEC")) {
                XNUCore_Base = seg->vmaddr;
                XNUCore_Size = seg->filesize;
            }
            else if (!strcmp(seg->segname, "__PPLTEXT")) {
                PPLText_base = seg->vmaddr;
                PPLText_size = seg->filesize;
            }
            else if (!strcmp(seg->segname, "__PLK_TEXT_EXEC")) {
                Prelink_Base = seg->vmaddr;
                Prelink_Size = seg->filesize;
            }
            else if (!strcmp(seg->segname, "__DATA_CONST")) {
                const struct section_64 *sec = (struct section_64 *)(seg + 1);
                for (j = 0; j < seg->nsects; j++) {
                    if (!strcmp(sec[j].sectname, "__const")) {
                        Data_const_base = sec[j].addr;
                        Data_const_size = sec[j].size;
                    }
                }
            }
            else if (!strcmp(seg->segname, "__DATA")) {
                const struct section_64 *sec = (struct section_64 *)(seg + 1);
                for (j = 0; j < seg->nsects; j++) {
                    if (!strcmp(sec[j].sectname, "__data")) {
                        Data_base = sec[j].addr;
                        Data_size = sec[j].size;
                    }
                }
            }
            else if (!strcmp(seg->segname, "__TEXT")) {
                const struct section_64 *sec = (struct section_64 *)(seg + 1);
                for (j = 0; j < seg->nsects; j++) {
                    if (!strcmp(sec[j].sectname, "__cstring")) {
                        CString_base = sec[j].addr;
                        CString_size = sec[j].size;
                    }
                    if (!strcmp(sec[j].sectname, "__os_log")) {
                        OSLog_base = sec[j].addr;
                        OSLog_size = sec[j].size;
                    }
                }
            }
            else if (!strcmp(seg->segname, "__PRELINK_TEXT")) {
                const struct section_64 *sec = (struct section_64 *)(seg + 1);
                for (j = 0; j < seg->nsects; j++) {
                    if (!strcmp(sec[j].sectname, "__text")) {
                        PString_base = sec[j].addr;
                        PString_size = sec[j].size;
                    }
                }
            }
            else if (!strcmp(seg->segname, "__LINKEDIT")) {
                Kernel_delta = seg->vmaddr - min - seg->fileoff;
            }
        }
        else if (cmd->cmd == LC_UNIXTHREAD) {
            uint32_t *ptr = (uint32_t *)(cmd + 1);
            uint32_t flavor = ptr[0];
            struct {
                uint64_t x[29];    /* General purpose registers x0-x28 */
                uint64_t fp;    /* Frame pointer x29 */
                uint64_t lr;    /* Link register x30 */
                uint64_t sp;    /* Stack pointer x31 */
                uint64_t pc;     /* Program counter */
                uint32_t cpsr;    /* Current program status register */
            } *thread = (void *)(ptr + 2);
            if (flavor == 6) {
                Kernel_entry = thread->pc;
            }
        }
        q = q + cmd->cmdsize;
    }
    
    KernDumpBase = min;
    XNUCore_Base -= KernDumpBase;
    Prelink_Base -= KernDumpBase;
    CString_base -= KernDumpBase;
    PString_base -= KernDumpBase;
    OSLog_base -= KernDumpBase;
    Data_base -= KernDumpBase;
    Data_const_base -= KernDumpBase;
    PPLText_base -= KernDumpBase;
    Kernel_size = max - min;
    
    Kernel = calloc(1, Kernel_size);
    if (!Kernel) {
        close(fd);
        return -1;
    }
    
    q = buf + sizeof(struct mach_header) + is64;
    for (i = 0; i < hdr->ncmds; i++) {
        const struct load_command *cmd = (struct load_command *)q;
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (struct segment_command_64 *)q;
            size_t sz = pread(fd, Kernel + seg->vmaddr - min, seg->filesize, seg->fileoff);
            if (sz != seg->filesize) {
                close(fd);
                free(Kernel);
                return -1;
            }
            if (!Kernel_mh) {
                Kernel_mh = Kernel + seg->vmaddr - min;
            }
            //printf("%s\n", seg->segname);
            if (!strcmp(seg->segname, "__LINKEDIT")) {
                Kernel_delta = seg->vmaddr - min - seg->fileoff;
            }
        }
        q = q + cmd->cmdsize;
    }
    
    Kernel += arch_off;
    
    close(fd);
    
    (void)base;
    return 0;
}

void
TermPatchfinder(void)
{
    Kernel -= arch_off;
    free(Kernel);
}

/* these operate on VA ******************************************************/

#define INSN_RET  0xD65F03C0, 0xFFFFFFFF
#define INSN_CALL 0x94000000, 0xFC000000
#define INSN_B    0x14000000, 0xFC000000
#define INSN_CBZ  0x34000000, 0xFC000000
#define INSN_ADRP 0x90000000, 0x9F000000
#define INSN_TBNZ 0x37000000, 0x7F000000

addr_t
Find_register_value(addr_t where, int reg)
{
    addr_t val;
    addr_t bof = 0;
    where -= KernDumpBase;
    if (where > XNUCore_Base) {
        bof = BOF64(Kernel, XNUCore_Base, where);
        if (!bof) {
            bof = XNUCore_Base;
        }
    } else if (where > Prelink_Base) {
        bof = BOF64(Kernel, Prelink_Base, where);
        if (!bof) {
            bof = Prelink_Base;
        }
    }
    val = Calc64(Kernel, bof, where, reg);
    if (!val) {
        return 0;
    }
    return val + KernDumpBase;
}

addr_t
Find_reference(addr_t to, int n, int type)
{
    addr_t ref, end;
    addr_t base;
    addr_t size;
    
    base = XNUCore_Base;
    size = XNUCore_Size;
    
    if (type == 1) {
        base = Prelink_Base;
        size = Prelink_Size;
    }
    
    if (type == 4) {
        base = PPLText_base;
        size = PPLText_size;
    }
    
    if (n <= 0) {
        n = 1;
    }
    end = base + size;
    to -= KernDumpBase;
    do {
        ref = XREF64(Kernel, base, end, to);
        if (!ref) {
            return 0;
        }
        base = ref + 4;
    } while (--n > 0);
    return ref + KernDumpBase;
}


addr_t
Find_strref(const char *string, int n, int type, bool exactMatch)
{
    uint8_t *str;
    addr_t base, size;
    
    if (type == 1) {
        base = PString_base;
        size = PString_size;
    }
    else if (type == 2) {
        base = OSLog_base;
        size = OSLog_size;
    }
    else if (type == 3) {
        base = Data_base;
        size = Data_size;
    }
    else {
        base = CString_base;
        size = CString_size;
    }
    
    str = Boyermoore_horspool_memmem(Kernel + base, size, (uint8_t *)string, strlen(string));
    
    if (exactMatch) {
        while (strcmp((char *)str, string)) {
            base += ((uint64_t)str - (uint64_t)Kernel - (uint64_t)base) + 1;
            size -= strlen((char *)str) + 1;
            str = Boyermoore_horspool_memmem(Kernel + base, size, (uint8_t *)string, strlen(string));
        }
    }
    
    if (!str) {
        return 0;
    }
    return Find_reference(str - Kernel + KernDumpBase, n, type);
}

/****** fun *******/

addr_t Find_add_x0_x0_0x40_ret(void) {
    addr_t off;
    uint32_t *k;
    k = (uint32_t *)(Kernel + XNUCore_Base);
    for (off = 0; off < XNUCore_Size - 4; off += 4, k++) {
        if (k[0] == 0x91010000 && k[1] == 0xD65F03C0) {
            return off + XNUCore_Base + KernDumpBase + KASLR_Slide;
        }
    }
    k = (uint32_t *)(Kernel + Prelink_Base);
    for (off = 0; off < Prelink_Size - 4; off += 4, k++) {
        if (k[0] == 0x91010000 && k[1] == 0xD65F03C0) {
            return off + Prelink_Base + KernDumpBase + KASLR_Slide;
        }
    }
    return 0;
}

uint64_t Find_allproc(void) {
    // Find the first reference to the string
    addr_t ref = Find_strref("\"pgrp_add : pgrp is dead adding process\"", 1, 0, false);
    if (!ref) {
        return 0;
    }
    ref -= KernDumpBase;
    
    uint32_t op_before = *(uint32_t *)(Kernel + ref - 8);
    if ((op_before & 0xFC000000) == 0x14000000) {
        ref = Find_reference(ref - 4 + KernDumpBase, 1, 0);
        if (!ref) {
            return 0;
        }
        ref -= KernDumpBase;
    }
    
    uint64_t start = BOF64(Kernel, XNUCore_Base, ref);
    if (!start) {
        return 0;
    }
    
    // Find AND W8, W8, #0xFFFFDFFF - it's a pretty distinct instruction
    addr_t weird_instruction = 0;
    for (int i = 4; i < 5*0x100; i+=4) {
        uint32_t op = *(uint32_t *)(Kernel + ref + i);
        if (op == 0x12127908) {
            weird_instruction = ref+i;
            break;
        }
    }
    if (!weird_instruction) {
        return 0;
    }
    
    uint64_t val = Calc64(Kernel, start, weird_instruction - 8, 8);
    if (!val) {
        printf("Failed to calculate x8");
        return 0;
    }
    
    return val + KernDumpBase + KASLR_Slide;
}

uint64_t Find_copyout(void) {
    // Find the first reference to the string
    addr_t ref = Find_strref("\"%s(%p, %p, %lu) - transfer too large\"", 2, 0, false);
    if (!ref) {
        return 0;
    }
    ref -= KernDumpBase;
    
    uint64_t start = 0;
    for (int i = 4; i < 0x100*4; i+=4) {
        uint32_t op = *(uint32_t*)(Kernel+ref-i);
        if (op == 0xd10143ff) { // SUB SP, SP, #0x50
            start = ref-i;
            break;
        }
    }
    if (!start) {
        return 0;
    }
    
    return start + KernDumpBase + KASLR_Slide;
}

uint64_t Find_bzero(void) {
    // Just find SYS #3, c7, c4, #1, X3, then get the start of that function
    addr_t off;
    uint32_t *k;
    k = (uint32_t *)(Kernel + XNUCore_Base);
    for (off = 0; off < XNUCore_Size - 4; off += 4, k++) {
        if (k[0] == 0xd50b7423) {
            off += XNUCore_Base;
            break;
        }
    }
    
    uint64_t start = BOF64(Kernel, XNUCore_Base, off);
    if (!start) {
        return 0;
    }
    
    return start + KernDumpBase + KASLR_Slide;
}

addr_t Find_bcopy(void) {
    // Jumps straight into memmove after switching x0 and x1 around
    // Guess we just find the switch and that's it
    addr_t off;
    uint32_t *k;
    k = (uint32_t *)(Kernel + XNUCore_Base);
    for (off = 0; off < XNUCore_Size - 4; off += 4, k++) {
        if (k[0] == 0xAA0003E3 && k[1] == 0xAA0103E0 && k[2] == 0xAA0303E1 && k[3] == 0xd503201F) {
            return off + XNUCore_Base + KernDumpBase + KASLR_Slide;
        }
    }
    k = (uint32_t *)(Kernel + Prelink_Base);
    for (off = 0; off < Prelink_Size - 4; off += 4, k++) {
        if (k[0] == 0xAA0003E3 && k[1] == 0xAA0103E0 && k[2] == 0xAA0303E1 && k[3] == 0xd503201F) {
            return off + Prelink_Base + KernDumpBase + KASLR_Slide;
        }
    }
    return 0;
}

uint64_t Find_rootvnode(void) {
    // Find the first reference to the string
    addr_t ref = Find_strref("/var/run/.vfs_rsrc_streams_%p%x", 1, 0, false);
    
    if (!ref) {
        return 0;
    }
    ref -= KernDumpBase;
    
    uint64_t start = BOF64(Kernel, XNUCore_Base, ref);
    if (!start) {
        return 0;
    }
    
    // Find MOV X9, #0x2000000000 - it's a pretty distinct instruction
    addr_t weird_instruction = 0;
    for (int i = 4; i < 4*0x100; i+=4) {
        uint32_t op = *(uint32_t *)(Kernel + ref - i);
        if (op == 0xB25B03E9) {
            weird_instruction = ref-i;
            break;
        }
    }
    if (!weird_instruction) {
        ref = Find_strref("/var/run/.vfs_rsrc_streams_%p%x", 2, 0, false);
        
        if (!ref) {
            return 0;
        }
        
        ref -= KernDumpBase;
        
        start = BOF64(Kernel, XNUCore_Base, ref);
        if (!start) {
            return 0;
        }
        
        for (int i = 4; i < 4*0x100; i+=4) {
            uint32_t op = *(uint32_t *)(Kernel + ref - i);
            if (op == 0xB25B03E9) {
                weird_instruction = ref-i;
                break;
            }
        }
        if (!weird_instruction) {
            return 0;
        }
    }
    
    uint64_t val = Calc64(Kernel, start, weird_instruction, 8);
    if (!val) {
        return 0;
    }
    
    return val + KernDumpBase + KASLR_Slide;
}


addr_t Find_vnode_lookup() {
    addr_t ref, call, bof, func;
    ref = Find_strref("/private/var/mobile", 0, 0, false);
    if (!ref) {
        return 0;
    }
    
    ref -= KernDumpBase;
    bof = BOF64(Kernel, XNUCore_Base, ref);
    if (!bof) {
        return 0;
    }
    
    call = Step64(Kernel, ref, ref - bof, INSN_CALL);
    if (!call) {
        ref = Find_strref("/private/var/mobile", 2, 0, false);
        if (!ref) {
            return 0;
        }
        ref -= KernDumpBase;
        
        bof = BOF64(Kernel, XNUCore_Base, ref);
        if (!bof) {
            return 0;
        }
        
        call = Step64(Kernel, ref, ref - bof, INSN_CALL);
        if (!call) {
            return 0;
        }
    }
    
    call += 4;
    call = Step64(Kernel, call, call - bof, INSN_CALL);
    if (!call) {
        return 0;
    }
    
    call += 4;
    call = Step64(Kernel, call, call - bof, INSN_CALL);
    if (!call) {
        return 0;
    }
    
    func = Follow_call64(Kernel, call);
    if (!func) {
        return 0;
    }
    
    return func + KernDumpBase + KASLR_Slide;
}

// this is so bad ik
addr_t Find_vfs_context_current(void) {
    uint64_t string = Find_strref("apfs_vnop_renamex", 5, 0, true);
    if (!string) {
        return 0;
    }
    string -= KernDumpBase;
    
    uint64_t call = Step64_back(Kernel, string, 100, INSN_CALL);
    if (!call) {
        return 0;
    }
    
    uint64_t call2 = Step64_back(Kernel, call - 4, 100, INSN_CALL);
    if (!call2) {
        return 0;
    }
    
    uint64_t func = Follow_call64(Kernel, call2);
    if (!func) {
        return 0;
    }
    return func + KernDumpBase + KASLR_Slide;
}

// strictly for new kernelcache formats. on older ones find string in prelink section instead
addr_t Find_vnode_put(void) {
    uint64_t str = Find_strref("%s:%d: UNSET root_to_xid - on next boot, volume will root to liv", 1, 0, false);
    if (!str) {
        return 0;
    }
    str -= KernDumpBase;
    
    uint64_t call = Step64(Kernel, str, 100, INSN_CALL);
    if (!call) {
        return 0;
    }
    
    uint64_t call2 = Step64(Kernel, call + 4, 100, INSN_CALL);
    if (!call2) {
        return 0;
    }
    
    uint64_t call3 = Step64(Kernel, call2 + 4, 100, INSN_CALL);
    if (!call3) {
        return 0;
    }
    
    uint64_t func = Follow_call64(Kernel, call3);
    if (!func) {
        return 0;
    }
    return func + KernDumpBase + KASLR_Slide;
}

addr_t Find_trustcache(void) {
    addr_t call, func, ref;
    
    ref = Find_strref("%s: only allowed process can check the trust cache", 1, 1, false);
    if (!ref) {
        ref = Find_strref("%s: only allowed process can check the trust cache", 1, 0, false);
        if (!ref) {
            return 0;
        }
    }
    ref -= KernDumpBase;
    
    call = Step64_back(Kernel, ref, 44, INSN_CALL);
    if (!call) {
        return 0;
    }
    
    func = Follow_call64(Kernel, call);
    if (!func) {
        return 0;
    }
    
    call = Step64(Kernel, func, 32, INSN_CALL);
    if (!call) {
        return 0;
    }
    
    func = Follow_call64(Kernel, call);
    if (!func) {
        return 0;
    }
    
    call = Step64(Kernel, func, 32, INSN_CALL);
    if (!call) {
        return 0;
    }
    
    call = Step64(Kernel, call + 4, 32, INSN_CALL);
    if (!call) {
        return 0;
    }
    
    func = Follow_call64(Kernel, call);
    if (!func) {
        return 0;
    }
    
    call = Step64(Kernel, func, 48, INSN_CALL);
    if (!call) {
        return 0;
    }
    
    uint64_t val = Calc64(Kernel, call, call + 24, 21);
    if (!val) {
        // iOS 12
        
        if (PPLText_size) {
            // A12
            
            ref = Find_strref("\"loadable trust cache buffer too small (%ld) for entries claimed (%d)\"", 1, 4, false);
            if (!ref) {
                return 0;
            }
            
            ref -= KernDumpBase;
            
            val = Calc64(Kernel, ref-32*4, ref-24*4, 8);
            if (!val) {
                return 0;
            }
            
            return val + KernDumpBase + KASLR_Slide;
        }
        else {
            ref = Find_strref("\"loadable trust cache buffer too small (%ld) for entries claimed (%d)\"", 1, 0, false);
        }
        
        if (!ref) {
            return 0;
        }
        ref -= KernDumpBase;
        
        val = Calc64(Kernel, ref-12*4, ref-12*4+12, 8);
        if (!val) {
            return 0;
        }
        return val + KernDumpBase + KASLR_Slide;
    }
    return val + KernDumpBase + KASLR_Slide;
}

addr_t Find_pmap_load_trust_cache_ppl() {
    uint64_t ref = Find_strref("%s: trust cache already loaded, ignoring", 2, 0, false);
    if (!ref) {
        ref = Find_strref("%s: trust cache already loaded, ignoring", 1, 0, false);
        if (!ref) {
            return 0;
        }
    }
    ref -= KernDumpBase;
    
    uint64_t func = Step64_back(Kernel, ref, 200, INSN_CALL);
    if (!func) {
        return 0;
    }
    
    func -= 4;
    
    func = Step64_back(Kernel, func, 200, INSN_CALL);
    if (!func) {
        return 0;
    }
    
    func = Follow_call64(Kernel, func);
    if (!func) {
        return 0;
    }
    
    return func + KernDumpBase + KASLR_Slide;
}

addr_t Find_amficache() {
    uint64_t cbz, call, func, val;
    uint64_t ref = Find_strref("amfi_prevent_old_entitled_platform_binaries", 1, 1, false);
    if (!ref) {
        // iOS 11
        ref = Find_strref("com.apple.MobileFileIntegrity", 0, 1, false);
        if (!ref) {
            return 0;
        }
        ref -= KernDumpBase;
        call = Step64(Kernel, ref, 64, INSN_CALL);
        if (!call) {
            return 0;
        }
        call = Step64(Kernel, call + 4, 64, INSN_CALL);
        goto okay;
    }
    ref -= KernDumpBase;
    cbz = Step64(Kernel, ref, 32, INSN_CBZ);
    if (!cbz) {
        return 0;
    }
    call = Step64(Kernel, Follow_cbz(Kernel, cbz), 4, INSN_CALL);
okay:
    if (!call) {
        return 0;
    }
    func = Follow_call64(Kernel, call);
    if (!func) {
        return 0;
    }
    val = Calc64(Kernel, func, func + 16, 8);
    if (!val) {
        ref = Find_strref("%s: only allowed process can check the trust cache", 1, 1, false); // Trying to find AppleMobileFileIntegrityUserClient::isCdhashInTrustCache
        if (!ref) {
            return 0;
        }
        ref -= KernDumpBase;
        call = Step64_back(Kernel, ref, 11*4, INSN_CALL);
        if (!call) {
            return 0;
        }
        func = Follow_call64(Kernel, call);
        if (!func) {
            return 0;
        }
        call = Step64(Kernel, func, 8*4, INSN_CALL);
        if (!call) {
            return 0;
        }
        func = Follow_call64(Kernel, call);
        if (!func) {
            return 0;
        }
        call = Step64(Kernel, func, 8*4, INSN_CALL);
        if (!call) {
            return 0;
        }
        call = Step64(Kernel, call+4, 8*4, INSN_CALL);
        if (!call) {
            return 0;
        }
        func = Follow_call64(Kernel, call);
        if (!func) {
            return 0;
        }
        call = Step64(Kernel, func, 12*4, INSN_CALL);
        if (!call) {
            return 0;
        }
        
        val = Calc64(Kernel, call, call + 6*4, 21);
    }
    return val + KernDumpBase + KASLR_Slide;
}


addr_t Find_zone_map_ref(void) {
    // \"Nothing being freed to the zone_map. start = end = %p\\n\"
    uint64_t val = KernDumpBase;
    
    addr_t ref = Find_strref("\"Nothing being freed to the zone_map. start = end = %p\\n\"", 1, 0, false);
    ref -= KernDumpBase;
    
    // skip add & adrp for panic str
    ref -= 8;
    
    // adrp xX, #_zone_map@PAGE
    ref = Step64_back(Kernel, ref, 30, INSN_ADRP);
    
    uint32_t *insn = (uint32_t*)(Kernel+ref);
    // get pc
    val += ((uint8_t*)(insn) - Kernel) & ~0xfff;
    uint8_t xm = *insn & 0x1f;
    
    // don't ask, I wrote this at 5am
    val += (*insn<<9 & 0x1ffffc000) | (*insn>>17 & 0x3000);
    
    // ldr x, [xX, #_zone_map@PAGEOFF]
    ++insn;
    if ((*insn & 0xF9C00000) != 0xF9400000) {
        return 0;
    }
    
    // xd == xX, xn == xX,
    if ((*insn&0x1f) != xm || ((*insn>>5)&0x1f) != xm) {
        return 0;
    }
    
    val += ((*insn >> 10) & 0xFFF) << 3;
    
    return val + KASLR_Slide;
}

addr_t Find_OSBoolean_True() {
    addr_t val;
    addr_t ref = Find_strref("Delay Autounload", 0, 0, false);
    if (!ref) {
        return 0;
    }
    ref -= KernDumpBase;
    
    addr_t weird_instruction = 0;
    for (int i = 4; i < 4*0x100; i+=4) {
        uint32_t op = *(uint32_t *)(Kernel + ref + i);
        if (op == 0x320003E0) {
            weird_instruction = ref+i;
            break;
        }
    }
    if (!weird_instruction) {
        ref = Find_strref("Delay Autounload", 2, 0, false);
        if (!ref) {
            return 0;
        }
        ref -= KernDumpBase;
        
        for (int i = 4; i < 4*0x100; i+=4) {
            uint32_t op = *(uint32_t *)(Kernel + ref + i);
            if (op == 0x320003E0) {
                weird_instruction = ref+i;
                break;
            }
        }
        if (!weird_instruction) {
            return 0;
        }
    }
    
    val = Calc64(Kernel, ref, weird_instruction, 8);
    if (!val) {
        return 0;
    }
    
    return KernelRead_64bits(val + KernDumpBase + KASLR_Slide);
}

addr_t Find_OSBoolean_False() {
    return Find_OSBoolean_True()+8;
}

addr_t Find_osunserializexml() {
    addr_t ref = Find_strref("OSUnserializeXML: %s near line %d\n", 1, 0, false);
    if (!ref) {
        return 0;
    }
    ref -= KernDumpBase;
    
    uint64_t start = BOF64(Kernel, XNUCore_Base, ref);
    if (!start) {
        return 0;
    }
    
    return start + KernDumpBase + KASLR_Slide;
}

addr_t Find_smalloc() {
    addr_t ref = Find_strref("sandbox memory allocation failure", 1, 1, false);
    if (!ref) {
        ref = Find_strref("sandbox memory allocation failure", 1, 2, false);
        if (!ref) {
            return 0;
        }
    }
    ref -= KernDumpBase;
    
    uint64_t start = BOF64(Kernel, Prelink_Base, ref);
    if (!start) {
        start = BOF64(Kernel, XNUCore_Base, ref);
        if (!start) {
            return 0;
        }
    }
    
    return start + KernDumpBase + KASLR_Slide;
}

addr_t Find_sbops() {
    addr_t off, what;
    uint8_t *str = Boyermoore_horspool_memmem(Kernel + PString_base, PString_size, (uint8_t *)"Seatbelt sandbox policy", sizeof("Seatbelt sandbox policy") - 1);
    if (!str) {
        return 0;
    }
    what = str - Kernel + KernDumpBase;
    for (off = 0; off < Kernel_size - Prelink_Base; off += 8) {
        if (*(uint64_t *)(Kernel + Prelink_Base + off) == what) {
            return *(uint64_t *)(Kernel + Prelink_Base + off + 24) + KASLR_Slide;
        }
    }
    return 0;
}

uint64_t Find_bootargs(void) {
    
    /*
     ADRP            X8, #_PE_state@PAGE
     ADD             X8, X8, #_PE_state@PAGEOFF
     LDR             X8, [X8,#(PE_state__boot_args - 0xFFFFFFF0078BF098)]
     ADD             X8, X8, #0x6C
     STR             X8, [SP,#0x550+var_550]
     ADRP            X0, #aBsdInitCannotF@PAGE ; "\"bsd_init: cannot find root vnode: %s"...
     ADD             X0, X0, #aBsdInitCannotF@PAGEOFF ; "\"bsd_init: cannot find root vnode: %s"...
     BL              _panic
     */
    
    addr_t ref = Find_strref("\"bsd_init: cannot find root vnode: %s\"", 1, 0, false);
    
    if (ref == 0) {
        return 0;
    }
    
    ref -= KernDumpBase;
    // skip add & adrp for panic str
    ref -= 8;
    uint32_t *insn = (uint32_t*)(Kernel+ref);
    
    // skip str
    --insn;
    // add xX, xX, #cmdline_offset
    uint8_t xm = *insn&0x1f;
    if (((*insn>>5)&0x1f) != xm || ((*insn>>22)&3) != 0) {
        return 0;
    }
    
    //cmdline_offset = (*insn>>10) & 0xfff;
    
    uint64_t val = KernDumpBase;
    
    --insn;
    // ldr xX, [xX, #(PE_state__boot_args - PE_state)]
    if ((*insn & 0xF9C00000) != 0xF9400000) {
        return 0;
    }
    // xd == xX, xn == xX,
    if ((*insn&0x1f) != xm || ((*insn>>5)&0x1f) != xm) {
        return 0;
    }
    
    val += ((*insn >> 10) & 0xFFF) << 3;
    
    --insn;
    // add xX, xX, #_PE_state@PAGEOFF
    if ((*insn&0x1f) != xm || ((*insn>>5)&0x1f) != xm || ((*insn>>22)&3) != 0) {
        return 0;
    }
    
    val += (*insn>>10) & 0xfff;
    
    --insn;
    if ((*insn & 0x1f) != xm) {
        return 0;
    }
    
    // pc
    val += ((uint8_t*)(insn) - Kernel) & ~0xfff;
    
    // don't ask, I wrote this at 5am
    val += (*insn<<9 & 0x1ffffc000) | (*insn>>17 & 0x3000);
    
    return val + KASLR_Slide;
}

addr_t Find_l2tp_domain_module_start() {
    uint64_t string = (uint64_t)Boyermoore_horspool_memmem(Kernel + Data_base, Data_size, (const unsigned char *)"com.apple.driver.AppleSynopsysOTGDevice", strlen("com.apple.driver.AppleSynopsysOTGDevice")) - (uint64_t)Kernel;
    if (!string) {
        return  0;
    }
    
    // uint64_t val = *(uint64_t*)(string + (uint64_t)Kernel - 0x20);
    // not sure if this is constant among all devices if (val == 0x8010000001821088) return string + KernDumpBase - 0x20;
    // return 0;
    
    return string + KernDumpBase - 0x20 + KASLR_Slide;
}

addr_t Find_l2tp_domain_module_stop() {
    uint64_t string = (uint64_t)Boyermoore_horspool_memmem(Kernel + Data_base, Data_size, (const unsigned char *)"com.apple.driver.AppleSynopsysOTGDevice", strlen("com.apple.driver.AppleSynopsysOTGDevice")) - (uint64_t)Kernel;
    if (!string) {
        return  0;
    }
    
    // uint64_t val = *(uint64_t*)(string + (uint64_t)Kernel - 0x20);
    // not sure if this is constant among all devices if (val == 0x8178000001821180) return string + KernDumpBase - 0x18;
    // return 0;
    
    return string + KernDumpBase - 0x18 + KASLR_Slide;
}

addr_t Find_l2tp_domain_inited() {
    uint64_t ref = Find_strref("L2TP domain init\n", 1, 0, true);
    if (!ref) {
        return 0;
    }
    ref -= KernDumpBase;
    
    uint64_t addr = Calc64(Kernel, ref, ref + 32, 8);
    if (!addr) {
        return 0;
    }
    
    return addr + KernDumpBase + KASLR_Slide;
}

addr_t Find_sysctl_net_ppp_l2tp() {
    uint64_t ref = Find_strref("L2TP domain terminate : PF_PPP domain does not exist...\n", 1, 0, true);
    if (!ref) {
        return 0;
    }
    ref -= KernDumpBase;
    ref += 4;
    
    uint64_t addr = Calc64(Kernel, ref, ref + 28, 0);
    if (!addr) {
        return 0;
    }
    
    return addr + KernDumpBase + KASLR_Slide;
}

addr_t Find_sysctl_unregister_oid() {
    uint64_t ref = Find_strref("L2TP domain terminate : PF_PPP domain does not exist...\n", 1, 0, true);
    if (!ref) {
        return 0;
    }
    ref -= KernDumpBase;
    
    uint64_t addr = Step64(Kernel, ref, 28, INSN_CALL);
    if (!addr) {
        return 0;
    }
    
    addr += 4;
    addr = Step64(Kernel, addr, 28, INSN_CALL);
    if (!addr) {
        return 0;
    }
    
    uint64_t call = Follow_call64(Kernel, addr);
    if (!call) {
        return 0;
    }
    return call + KernDumpBase + KASLR_Slide;
}

addr_t Find_mov_x0_x4__br_x5() {
    uint32_t bytes[] = {
        0xaa0403e0, // mov x0, x4
        0xd61f00a0  // br x5
    };
    
    uint64_t addr = (uint64_t)Boyermoore_horspool_memmem((unsigned char *)((uint64_t)Kernel + XNUCore_Base), XNUCore_Size, (const unsigned char *)bytes, sizeof(bytes));
    if (!addr) {
        return 0;
    }
    
    return addr - (uint64_t)Kernel + KernDumpBase + KASLR_Slide;
}

addr_t Find_mov_x9_x0__br_x1() {
    uint32_t bytes[] = {
        0xaa0003e9, // mov x9, x0
        0xd61f0020  // br x1
    };
    
    uint64_t addr = (uint64_t)Boyermoore_horspool_memmem((unsigned char *)((uint64_t)Kernel + XNUCore_Base), XNUCore_Size, (const unsigned char *)bytes, sizeof(bytes));
    if (!addr) {
        return 0;
    }
    
    return addr - (uint64_t)Kernel + KernDumpBase + KASLR_Slide;
}

addr_t Find_mov_x10_x3__br_x6() {
    uint32_t bytes[] = {
        0xaa0303ea, // mov x10, x3
        0xd61f00c0  // br x6
    };
    
    uint64_t addr = (uint64_t)Boyermoore_horspool_memmem((unsigned char *)((uint64_t)Kernel + XNUCore_Base), XNUCore_Size, (const unsigned char *)bytes, sizeof(bytes));
    if (!addr) {
        return 0;
    }
    
    return addr - (uint64_t)Kernel + KernDumpBase + KASLR_Slide;
}

addr_t Find_kernel_forge_pacia_gadget() {
    
    uint32_t bytes[] = {
        0xdac10149, // paci
        0xf9007849  // str x9, [x2, #240]
    };
    
    uint64_t addr = (uint64_t)Boyermoore_horspool_memmem((unsigned char *)((uint64_t)Kernel + XNUCore_Base), XNUCore_Size, (const unsigned char *)bytes, sizeof(bytes));
    if (!addr) {
        return 0;
    }
    
    return addr - (uint64_t)Kernel + KernDumpBase + KASLR_Slide;
}

addr_t Find_kernel_forge_pacda_gadget() {
    
    uint32_t bytes[] = {
        0xdac10949, // pacd x9
        0xf9007449  // str x9, [x2, #232]
    };
    
    uint64_t addr = (uint64_t)Boyermoore_horspool_memmem((unsigned char *)((uint64_t)Kernel + XNUCore_Base), XNUCore_Size, (const unsigned char *)bytes, sizeof(bytes));
    if (!addr) {
        return 0;
    }
    
    return addr - (uint64_t)Kernel + KernDumpBase + KASLR_Slide;
}

addr_t Find_IOUserClient_vtable() {
    uint64_t ref1 = Find_strref("IOUserClient", 2, 0, true);
    if (!ref1) {
        return 0;
    }
    ref1 -= KernDumpBase;
    
    uint64_t ref2 = Find_strref("IOUserClient", 3, 0, true);
    if (!ref2) {
        return 0;
    }
    ref2 -= KernDumpBase;
    
    uint64_t func2 = BOF64(Kernel, XNUCore_Base, ref2);
    if (!func2) {
        return 0;
    }
    
    uint64_t vtable = Calc64(Kernel, ref1, func2, 8);
    if (!vtable) {
        return 0;
    }
    
    //vtable -= 0x10;
    
    return vtable + KernDumpBase + KASLR_Slide;
}

addr_t Find_IORegistryEntry__getRegistryEntryID() {
    
    uint32_t bytes[] = {
        0xf9400808, // ldr x8, [x0, #0x10]
    };
    
    uint64_t addr = (uint64_t)Boyermoore_horspool_memmem((unsigned char *)((uint64_t)Kernel + XNUCore_Base), XNUCore_Size, (const unsigned char *)bytes, sizeof(bytes));
    if (!addr) {
        return 0;
    }
    
    // basically just look the instructions
    // can't find a better way
    // this was not done like the previous gadgets because an address is being used, which won't be the same between devices so can't be hardcoded and i gotta use masks
    
    // cbz x8, SOME_ADDRESS <= where we do masking (((*(uint32_t *)(addr + 4)) & 0xFC000000) != 0xb4000000)
    // ldr x0, [x8, #8]     <= 2nd part of 0xd65f03c0f9400500
    // ret                  <= 1st part of 0xd65f03c0f9400500
    
    while ((((*(uint32_t *)(addr + 4)) & 0xFC000000) != 0xb4000000) || (*(uint64_t*)(addr + 8) != 0xd65f03c0f9400500)) {
        addr = (uint64_t)Boyermoore_horspool_memmem((unsigned char *)(addr + 4), XNUCore_Size, (const unsigned char *)bytes, sizeof(bytes));
    }
    
    return addr + KernDumpBase - (uint64_t)Kernel + KASLR_Slide;
}

addr_t Find_cs_gen_count() {
    uint64_t ref = Find_strref("CS Platform Exec Logging: Executing platform signed binary '%s'", 1, 2, false);
    if (!ref) {
        return 0;
    }
    ref -= KernDumpBase;
    
    uint64_t addr = Step64(Kernel, ref, 200, INSN_ADRP);
    if (!addr) {
        return 0;
    }
    
    addr = Calc64(Kernel, addr, addr + 12, 25);
    if (!addr) {
        return 0;
    }
    
    return addr + KernDumpBase + KASLR_Slide;
}


addr_t Find_cs_validate_csblob() {
    
    uint32_t bytes[] = {
        0x52818049, // mov w9, #0xC02
        0x72bf5bc9, // movk w9, #0xfade, lsl#16
        0x6b09011f  // cmp w8, w9
    };
    
    uint64_t addr = (uint64_t)Boyermoore_horspool_memmem((unsigned char *)((uint64_t)Kernel + XNUCore_Base), XNUCore_Size, (const unsigned char *)bytes, sizeof(bytes));
    if (!addr) {
        return 0;
    }
    
    addr -= (uint64_t)Kernel;
    addr = BOF64(Kernel, XNUCore_Base, addr);
    if (!addr) {
        return 0;
    }
    
    return addr + KernDumpBase + KASLR_Slide;
}

addr_t Find_kalloc_canblock() {
    
    uint32_t bytes[] = {
        0xaa0003f3, // mov x19, x0
        0xf9400274, // ldr x20, [x19]
        0xf11fbe9f  // cmp x20, #0x7ef
    };
    
    uint64_t addr = (uint64_t)Boyermoore_horspool_memmem((unsigned char *)((uint64_t)Kernel + XNUCore_Base), XNUCore_Size, (const unsigned char *)bytes, sizeof(bytes));
    if (!addr) {
        return 0;
    }
    addr -= (uint64_t)Kernel;
    
    addr = BOF64(Kernel, XNUCore_Base, addr);
    if (!addr) {
        return 0;
    }
    
    return addr + KernDumpBase + KASLR_Slide;
}

addr_t Find_cs_blob_allocate_site() {
    
    uint32_t bytes[] = {
        0xf9001ea8, // str x8, [x21, #0x38]
        0xb9000ebf, // str wzr, [x21, #0xc]
        0x3942a2a8, // ldrb 28, [x21, #0xa8]
        0x121e1508, // and w8, w8, #0xfc
    };
    
    uint64_t addr = (uint64_t)Boyermoore_horspool_memmem((unsigned char *)((uint64_t)Kernel + XNUCore_Base), XNUCore_Size, (const unsigned char *)bytes, sizeof(bytes));
    if (!addr) {
        return 0;
    }
    addr -= (uint64_t)Kernel;
    
    addr = Step64_back(Kernel, addr, 200, INSN_ADRP);
    if (!addr) {
        return 0;
    }
    
    addr = Calc64(Kernel, addr, addr + 8, 2);
    if (!addr) {
        return 0;
    }
    
    return addr + KernDumpBase + KASLR_Slide;
}

addr_t Find_kfree() {
    
    uint32_t bytes[] = {
        0xf9001ea8, // str x8, [x21, #0x38]
        0xb9000ebf, // str wzr, [x21, #0xc]
        0x3942a2a8, // ldrb 28, [x21, #0xa8]
        0x121e1508, // and w8, w8, #0xfc
    };
    
    uint64_t addr = (uint64_t)Boyermoore_horspool_memmem((unsigned char *)((uint64_t)Kernel + XNUCore_Base), XNUCore_Size, (const unsigned char *)bytes, sizeof(bytes));
    if (!addr) {
        return 0;
    }
    addr -= (uint64_t)Kernel;
    
    addr = Step64(Kernel, addr, 200, INSN_CALL);
    if (!addr) {
        return 0;
    }
    
    addr += 4;
    
    addr = Step64(Kernel, addr, 200, INSN_CALL);
    if (!addr) {
        return 0;
    }
    
    addr = Follow_call64(Kernel, addr);
    if (!addr) {
        return 0;
    }
    
    return addr + KernDumpBase + KASLR_Slide;
}

addr_t Find_cs_find_md() {
    
    uint32_t bytes[] = {
        0xb9400008, // ldr w8, [x0]
        0x529bdf49, // mov w9, #0xdefa
        0x72a04189, // movk w9, #0x20c, lsl#16
        0x6b09011f  // cmp w8, w9
    };
    
    uint64_t addr = (uint64_t)Boyermoore_horspool_memmem((unsigned char *)((uint64_t)Kernel + XNUCore_Base), XNUCore_Size, (const unsigned char *)bytes, sizeof(bytes));
    if (!addr) {
        return 0;
    }
    
    addr -= (uint64_t)Kernel;
    
    uint64_t adrp = Step64(Kernel, addr, 200, INSN_ADRP);
    if (!adrp) {
        return 0;
    }
    
    adrp += 4;
    
    uint64_t adrp2 = Step64(Kernel, adrp, 200, INSN_ADRP);
    if (adrp2) {
        adrp = adrp2; // non-A12
    }
    
    addr = Calc64(Kernel, adrp - 4, adrp + 8, 9);
    if (!addr) {
        return 0;
    }
    
    return addr + KernDumpBase + KASLR_Slide;
}

addr_t Find_kernel_memory_allocate() {
    uint64_t ref = Find_strref("\"kernel_memory_allocate: VM is not ready\"", 1, 0, true);
    if (!ref) {
        return 0;
    }
    ref -= KernDumpBase;
    
    uint64_t func = BOF64(Kernel, XNUCore_Base, ref);
    if (!func) {
        return 0;
    }
    
    return func + KernDumpBase + KASLR_Slide;
}

addr_t Find_kernel_map() {
    uint64_t kalloc_canblock = Find_kalloc_canblock();
    if (!kalloc_canblock) {
        return 0;
    }
    kalloc_canblock -= (KernDumpBase + KASLR_Slide);
    
    uint64_t kern_alloc = Find_kernel_memory_allocate();
    if (!kern_alloc) {
        return 0;
    }
    kern_alloc -= (KernDumpBase + KASLR_Slide);
    
    uint64_t val = 0;
    uint64_t func = kalloc_canblock;
    
    for (int i = 0; i < 5; i++) {
        func = Step64(Kernel, func + 4, 4*80, INSN_CALL);
        
        if (Follow_call64(Kernel, func) == kern_alloc) {
            val = Calc64(Kernel, kalloc_canblock, func, 10);
            break;
        }
    }
    
    if (!val) {
        return 0;
    }
    
    return val + KernDumpBase + KASLR_Slide;
}
