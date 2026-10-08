#pragma once

#import <AppKit/AppKit.h>

#define CIO_NATIVE_EXPORT __attribute__((visibility("default")))

#ifdef __cplusplus
extern "C" {
#endif
CIO_NATIVE_EXPORT int CioNativeStart(int argc, const char **argv);
CIO_NATIVE_EXPORT BOOL CioNativeIsInitialized(void);
CIO_NATIVE_EXPORT void CioNativeShutdown(void);
CIO_NATIVE_EXPORT void CioNativePump(void);
CIO_NATIVE_EXPORT void CioNativeFlushCookies(void (^completion)(BOOL));
CIO_NATIVE_EXPORT void CioNativeSetDarkAppearance(BOOL dark);
#ifdef __cplusplus
}
#endif
