//
//  main.m
//  odysseypayload
//
//  Created by master on 2021/4/18.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <pthread.h>
#import <dlfcn.h>
#import <CoreFoundation/CoreFoundation.h>



void* threadproc2(void* p)
{
    sleep(2);
    


NSLog (@ "odysseypayload loadlib %x %s", dlopen("/usr/lib/acore/AppSyncUnified-FrontBoard.dylib", RTLD_NOW), dlerror());
    
    return 0;

}

void* threadproc(void* p)
{
    sleep(2);
    
    NSLog (@ "odysseypayload thread coming %d", [[NSThread currentThread] isMainThread]);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        NSLog (@ "odysseypayload thread coming %d", [[NSThread currentThread] isMainThread]);
        
        
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"我在干嘛?" message:@"我在越狱啊" preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"好吧" style:UIAlertActionStyleDefault handler:nil]];
        
        [[window rootViewController] presentViewController:alert animated:YES completion:nil];
    });
    
    return 0;

}


__attribute__ ( (constructor ) ) static void initfunc()
{
    unsetenv("DYLD_INSERT_LIBRARIES");
    
    NSString *package = [[NSBundle mainBundle] bundleIdentifier];
    NSString *pname = [[NSProcessInfo processInfo] processName];
    NSString *path = [[NSBundle mainBundle] bundlePath];
    
    NSLog (@ "odysseypayload inject %@ %@ %@", package, pname, path);
    
    
    if([package isEqual:@"com.apple.xpc.proxy"])
    {
        NSLog(@"odysseypayload hit xpcproxy %d", getpid());
        
        //pspawn_payload.dylib
        void* pspawn_payload = dlopen("/usr/lib/acore/libodsp1.dylib", RTLD_NOW);
        NSLog (@ "odysseypayload pspawn_payload.dylib %x %s", pspawn_payload, dlerror());
        
    } else {
        
        //pspawn_payload-stg2.dylib
        void* pspawn_payload = dlopen("/usr/lib/acore/libodsp2.dylib", RTLD_NOW);
        NSLog (@ "odysseypayload pspawn_payload-stg2.dylib %x %s", pspawn_payload, dlerror());
        
    }

    
    if([package isEqual:@"com.apple.backboardd"])
    {
        NSLog(@"odysseypayload hit backboardd %d", getpid());
        
        
        NSLog (@ "odysseypayload loadlib %x %s", dlopen("/Applications/TouchSprite.app/MobileSubstrate/DynamicLibraries/TSEventTweak.dylib", RTLD_NOW), dlerror());
    }


    if([package isEqual:@"com.apple.springboard"])
    {
        NSLog(@"odysseypayload hit springboard %d", getpid());
        
        
//        NSLog (@ "odysseypayload loadlib %x %s", dlopen("/usr/lib/acore/libmss.dylib", RTLD_NOW), dlerror());
        
        NSLog (@ "odysseypayload loadlib %x %s", dlopen("/Applications/TouchSprite.app/MobileSubstrate/DynamicLibraries/TSTweak.dylib", RTLD_NOW), dlerror());
        
//        NSLog (@ "odysseypayload loadlib %x %s",      dlopen("/Library/MobileSubstrate/DynamicLibraries/TSActivator.dylib", RTLD_NOW), dlerror());
    }
    
    
    if([pname isEqual:@"installd"])
    {
        NSLog(@"odysseypayload hit installd %d", getpid());
        
        
        NSLog (@ "odysseypayload loadlib %x %s", dlopen("/usr/lib/acore/AppSyncUnified-installd.dylib", RTLD_NOW), dlerror());
        
        //void initappsync();
        //initappsync();
    }
    
//    if([package isEqual:@"com.apple.springboard"])
//    {
//        NSLog(@"odysseypayload hit installd %d", getpid());
//        pthread_t thread1;
//        pthread_attr_t att;
//        pthread_attr_init(&att);
//        int result = pthread_create(&thread1, &att, threadproc2, nil);
//    }
    
    if([path containsString:@"/var/containers/Bundle/Application/"])
    {
        pthread_t thread1;
        pthread_attr_t att;
        pthread_attr_init(&att);
        int result = pthread_create(&thread1, &att, threadproc, nil);
    }
}

