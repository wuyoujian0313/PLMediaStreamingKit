//
//  PREDCrashCXXExceptionHandler.mm
//  PreDemObjc
//
//  Created by WangSiyu on 21/02/2017.
//  Copyright © 2017 pre-engineering. All rights reserved.
//

#import "PreDemObjc.h"
#import "PREDCrashCXXExceptionHandler.h"
#import <vector>
#import <cxxabi.h>
#import <exception>
#import <stdexcept>
#import <typeinfo>
#import <string>
#import <pthread.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <libkern/OSAtomic.h>

typedef std::vector<PREDCrashUncaughtCXXExceptionHandler> PREDCrashUncaughtCXXExceptionHandlerList;
typedef struct
{
    void *exception_object;
    uintptr_t call_stack[128];
    uint32_t num_frames;
} PREDCrashCXXExceptionTSInfo;

static bool _PREDCrashIsOurTerminateHandlerInstalled = false;
static std::terminate_handler _PREDCrashOriginalTerminateHandler = nullptr;
static PREDCrashUncaughtCXXExceptionHandlerList _PREDCrashUncaughtExceptionHandlerList;
static OSSpinLock _PREDCrashCXXExceptionHandlingLock = OS_SPINLOCK_INIT;
static pthread_key_t _PREDCrashCXXExceptionInfoTSDKey = 0;

@implementation PREDCrashUncaughtCXXExceptionHandlerManager

extern "C" void LIBCXXABI_NORETURN __cxa_throw(void *exception_object, std::type_info *tinfo, void (*dest)(void *))
{
    // Purposely do not take a lock in this function. The aim is to be as fast as
    // possible. While we could really use some of the info set up by the real
    // __cxa_throw, if we call through we never get control back - the function is
    // noreturn and jumps to landing pads. Most of the stuff in __cxxabiv1 also
    // won't work yet. We therefore have to do these checks by hand.
    
    // The technique for distinguishing Objective-C exceptions is based on the
    // implementation of objc_exception_throw(). It's weird, but it's fast. The
    // explicit symbol load and NULL checks should guard against the
    // implementation changing in a future version. (Or not existing in an earlier
    // version).
    
    typedef void (*cxa_throw_func)(void *, std::type_info *, void (*)(void *)) LIBCXXABI_NORETURN;
    static dispatch_once_t predicate = 0;
    static cxa_throw_func __original__cxa_throw = nullptr;
    static const void **__real_objc_ehtype_vtable = nullptr;
    
    dispatch_once(&predicate, ^ {
        __original__cxa_throw = reinterpret_cast<cxa_throw_func>(dlsym(RTLD_NEXT, "__cxa_throw"));
        __real_objc_ehtype_vtable = reinterpret_cast<const void **>(dlsym(RTLD_DEFAULT, "objc_ehtype_vtable"));
    });
    
    // Actually check for Objective-C exceptions.
    if (tinfo && __real_objc_ehtype_vtable && // Guard from an ABI change
        *reinterpret_cast<void **>(tinfo) == __real_objc_ehtype_vtable + 2) {
        goto callthrough;
    }
    
    // Any other exception that came here has to be C++, since Objective-C is the
    // only (known) runtime that hijacks the C++ ABI this way. We need to save off
    // a backtrace.
    // Invariant: If the terminate handler is installed, the TSD key must also be
    // initialized.
    if (_PREDCrashIsOurTerminateHandlerInstalled) {
        PREDCrashCXXExceptionTSInfo *info = static_cast<PREDCrashCXXExceptionTSInfo *>(pthread_getspecific(_PREDCrashCXXExceptionInfoTSDKey));
        
        if (!info) {
            info = reinterpret_cast<PREDCrashCXXExceptionTSInfo *>(calloc(1, sizeof(PREDCrashCXXExceptionTSInfo)));
            pthread_setspecific(_PREDCrashCXXExceptionInfoTSDKey, info);
        }
        info->exception_object = exception_object;
        // XXX: All significant time in this call is spent right here.
        info->num_frames = backtrace(reinterpret_cast<void **>(&info->call_stack[0]), sizeof(info->call_stack) / sizeof(info->call_stack[0]));
    }
    
callthrough:
    if (__original__cxa_throw) {
        __original__cxa_throw(exception_object, tinfo, dest);
    } else {
        abort();
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunreachable-code"
    __builtin_unreachable();
#pragma clang diagnostic pop
}

__attribute__((always_inline))
static inline void PREDCrashIterateExceptionHandlers_unlocked(const PREDCrashUncaughtCXXExceptionInfo &info)
{
    for (const auto &handler : _PREDCrashUncaughtExceptionHandlerList) {
        handler(&info);
    }
}

static void PREDCrashUncaughtCXXTerminateHandler(void)
{
    PREDCrashUncaughtCXXExceptionInfo info = {
        .exception = nullptr,
        .exception_type_name = nullptr,
        .exception_message = nullptr,
        .exception_frames_count = 0,
        .exception_frames = nullptr,
    };
    auto p = std::current_exception();
    
    OSSpinLockLock(&_PREDCrashCXXExceptionHandlingLock); {
        if (p) { // explicit operator bool
            info.exception = reinterpret_cast<const void *>(&p);
            info.exception_type_name = __cxxabiv1::__cxa_current_exception_type()->name();
            
            PREDCrashCXXExceptionTSInfo *recorded_info = reinterpret_cast<PREDCrashCXXExceptionTSInfo *>(pthread_getspecific(_PREDCrashCXXExceptionInfoTSDKey));
            
            if (recorded_info) {
                info.exception_frames_count = recorded_info->num_frames - 1;
                info.exception_frames = &recorded_info->call_stack[1];
            } else {
                // There's no backtrace, grab this function's trace instead. Probably
                // means the exception came from a dynamically loaded library.
                void *frames[128] = { nullptr };
                
                info.exception_frames_count = backtrace(&frames[0], sizeof(frames) / sizeof(frames[0])) - 1;
                info.exception_frames = reinterpret_cast<uintptr_t *>(&frames[1]);
            }
            
            try {
                std::rethrow_exception(p);
            } catch (const std::exception &e) { // C++ exception.
                info.exception_message = e.what();
                PREDCrashIterateExceptionHandlers_unlocked(info);
            } catch (const std::exception *e) { // C++ exception by pointer.
                info.exception_message = e->what();
                PREDCrashIterateExceptionHandlers_unlocked(info);
            } catch (const std::string &e) { // C++ string as exception.
                info.exception_message = e.c_str();
                PREDCrashIterateExceptionHandlers_unlocked(info);
            } catch (const std::string *e) { // C++ string pointer as exception.
                info.exception_message = e->c_str();
                PREDCrashIterateExceptionHandlers_unlocked(info);
            } catch (const char *e) { // Plain string as exception.
                info.exception_message = e;
                PREDCrashIterateExceptionHandlers_unlocked(info);
            } catch (id e) { // Objective-C exception. Pass it on to Foundation.
                OSSpinLockUnlock(&_PREDCrashCXXExceptionHandlingLock);
                if (_PREDCrashOriginalTerminateHandler != nullptr) {
                    _PREDCrashOriginalTerminateHandler();
                }
                return;
            } catch (...) { // Any other kind of exception. No message.
                PREDCrashIterateExceptionHandlers_unlocked(info);
            }
        }
    } OSSpinLockUnlock(&_PREDCrashCXXExceptionHandlingLock); // In case terminate is called reentrantly by pasing it on
    
    if (_PREDCrashOriginalTerminateHandler != nullptr) {
        _PREDCrashOriginalTerminateHandler();
    } else {
        abort();
    }
}

+ (void)addCXXExceptionHandler:(PREDCrashUncaughtCXXExceptionHandler)handler
{
    static dispatch_once_t key_predicate = 0;
    
    // This only EVER has to be done once, since we don't delete the TSD later
    // (there's no reason to delete it).
    dispatch_once(&key_predicate, ^ {
        pthread_key_create(&_PREDCrashCXXExceptionInfoTSDKey, free);
    });
    
    OSSpinLockLock(&_PREDCrashCXXExceptionHandlingLock); {
        if (!_PREDCrashIsOurTerminateHandlerInstalled) {
            _PREDCrashOriginalTerminateHandler = std::set_terminate(PREDCrashUncaughtCXXTerminateHandler);
            _PREDCrashIsOurTerminateHandlerInstalled = true;
        }
        _PREDCrashUncaughtExceptionHandlerList.push_back(handler);
    } OSSpinLockUnlock(&_PREDCrashCXXExceptionHandlingLock);
}

+ (void)removeCXXExceptionHandler:(PREDCrashUncaughtCXXExceptionHandler)handler
{
    OSSpinLockLock(&_PREDCrashCXXExceptionHandlingLock); {
        auto i = std::find(_PREDCrashUncaughtExceptionHandlerList.begin(), _PREDCrashUncaughtExceptionHandlerList.end(), handler);
        
        if (i != _PREDCrashUncaughtExceptionHandlerList.end()) {
            _PREDCrashUncaughtExceptionHandlerList.erase(i);
        }
        
        if (_PREDCrashIsOurTerminateHandlerInstalled) {
            if (_PREDCrashUncaughtExceptionHandlerList.empty()) {
                std::terminate_handler previous_handler = std::set_terminate(_PREDCrashOriginalTerminateHandler);
                
                if (previous_handler != PREDCrashUncaughtCXXTerminateHandler) {
                    std::set_terminate(previous_handler);
                } else {
                    _PREDCrashIsOurTerminateHandlerInstalled = false;
                    _PREDCrashOriginalTerminateHandler = nullptr;
                }
            }
        }
    } OSSpinLockUnlock(&_PREDCrashCXXExceptionHandlingLock);
}

@end