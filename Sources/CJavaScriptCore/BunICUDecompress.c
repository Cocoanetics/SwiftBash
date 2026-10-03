// `bun_icu_maybe_decompress`: unpacks the compressed items of Bun's ICU data.
//
// Bun's Linux archives built since May 2026 (oven-sh/WebKit#237) ship a
// repacked libicudata.a in which some items — display names in every locale
// (curr/, lang/, region/, unit/, zone/) — are zstd frames, and an ICU patched
// to call this weak hook on every item it loads. Without a definition the
// hook is skipped and ICU can't read those items: `Intl.DisplayNames` returns
// bare codes, `currencyDisplay: 'name'` and `timeZoneName` throw. Bun defines
// it in src/jsc/bindings/bun_icu_decompress.cpp; this is a C port of that.
//
// Raw items keep ICU's 0xda27 header, so their first word is never zstd's
// magic number and they pass straight through. A decompressed item is cached
// for the life of the process, keyed by its address in libicudata.a.
//
// Linux only: Bun's Android image doesn't compress its ICU data, and Apple
// platforms use the system ICU.
#if defined(__linux__) && !defined(__ANDROID__)

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <zstd.h>

// Defined by the repacked libicudata.a. Referenced strongly on purpose: a
// weak reference wouldn't pull the archive member that holds the dictionary.
extern const unsigned char bun_icu_zstd_dict[];
extern const unsigned int bun_icu_zstd_dict_size;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static ZSTD_DCtx* context;
static ZSTD_DDict* dictionary;

// Open-addressing map from compressed item to its decompressed copy.
struct entry {
    const void* item;
    void* data;
};
static struct entry* entries;
static size_t capacity;
static size_t count;

static size_t slot(const void* item)
{
    return (size_t)(((uintptr_t)item >> 4) * 0x9E3779B97F4A7C15ull) & (capacity - 1);
}

static void* lookup(const void* item)
{
    if (!capacity)
        return NULL;
    for (size_t i = slot(item);; i = (i + 1) & (capacity - 1)) {
        if (!entries[i].item)
            return NULL;
        if (entries[i].item == item)
            return entries[i].data;
    }
}

static int insert(const void* item, void* data)
{
    if ((count + 1) * 2 > capacity) {
        size_t oldCapacity = capacity;
        struct entry* oldEntries = entries;
        size_t newCapacity = capacity ? capacity * 2 : 64;
        struct entry* newEntries = calloc(newCapacity, sizeof(struct entry));
        if (!newEntries)
            return 0;
        entries = newEntries;
        capacity = newCapacity;
        for (size_t i = 0; i < oldCapacity; i++) {
            if (!oldEntries[i].item)
                continue;
            size_t j = slot(oldEntries[i].item);
            while (entries[j].item)
                j = (j + 1) & (capacity - 1);
            entries[j] = oldEntries[i];
        }
        free(oldEntries);
    }
    size_t i = slot(item);
    while (entries[i].item)
        i = (i + 1) & (capacity - 1);
    entries[i].item = item;
    entries[i].data = data;
    count++;
    return 1;
}

const void* bun_icu_maybe_decompress(const void* item, int32_t* length)
{
    if (!item)
        return item;
    uint32_t magic;
    memcpy(&magic, item, sizeof magic);
    if (magic != ZSTD_MAGICNUMBER)
        return item;

    const void* result = item;
    pthread_mutex_lock(&lock);
    if (!context) {
        context = ZSTD_createDCtx();
        if (bun_icu_zstd_dict_size)
            dictionary = ZSTD_createDDict(bun_icu_zstd_dict, bun_icu_zstd_dict_size);
    }
    size_t bound = *length > 0 ? (size_t)*length : (size_t)1 << 20;
    size_t compressedSize = ZSTD_findFrameCompressedSize(item, bound);
    unsigned long long size = ZSTD_isError(compressedSize)
        ? ZSTD_CONTENTSIZE_ERROR
        : ZSTD_getFrameContentSize(item, compressedSize);
    if (context && size != ZSTD_CONTENTSIZE_UNKNOWN && size != ZSTD_CONTENTSIZE_ERROR) {
        void* cached = lookup(item);
        if (cached) {
            *length = (int32_t)size;
            result = cached;
        } else {
            void* data = aligned_alloc(16, ((size_t)size + 15) & ~(size_t)15);
            if (data) {
                size_t written = dictionary
                    ? ZSTD_decompress_usingDDict(context, data, (size_t)size, item, compressedSize, dictionary)
                    : ZSTD_decompressDCtx(context, data, (size_t)size, item, compressedSize);
                if (!ZSTD_isError(written) && insert(item, data)) {
                    *length = (int32_t)size;
                    result = data;
                } else {
                    free(data);
                }
            }
        }
    }
    pthread_mutex_unlock(&lock);
    return result;
}

#endif
