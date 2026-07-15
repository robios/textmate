/* Pre-generated replacement for CMake's generate_export_header() output.
   We only build the static library, so all visibility macros are empty
   (equivalent to upstream's CMARK_GFM_STATIC_DEFINE branch). */
#ifndef CMARK_GFM_EXPORT_H
#define CMARK_GFM_EXPORT_H

#define CMARK_GFM_EXPORT
#define CMARK_GFM_NO_EXPORT

#ifndef CMARK_GFM_DEPRECATED
#  define CMARK_GFM_DEPRECATED __attribute__ ((__deprecated__))
#endif

#ifndef CMARK_GFM_DEPRECATED_EXPORT
#  define CMARK_GFM_DEPRECATED_EXPORT CMARK_GFM_EXPORT CMARK_GFM_DEPRECATED
#endif

#ifndef CMARK_GFM_DEPRECATED_NO_EXPORT
#  define CMARK_GFM_DEPRECATED_NO_EXPORT CMARK_GFM_NO_EXPORT CMARK_GFM_DEPRECATED
#endif

#endif /* CMARK_GFM_EXPORT_H */
