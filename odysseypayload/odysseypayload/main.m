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


__attribute__ ( (constructor ) ) static void EntryPoint ( )
{
    unsetenv("DYLD_INSERT_LIBRARIES");
    
    NSLog (@ "odysseypayload inject %d %d", getpid(), [[NSThread currentThread] isMainThread]);
    
    //pspawn_payload-stg2.dylib
    void* pspawn_payload = dlopen("/usr/lib/libodsp.dylib", RTLD_NOW);
    NSLog (@ "odysseypayload pspawn_payload-stg2.dylib %x", pspawn_payload);
    
    pthread_t thread1;
    pthread_attr_t att;
    pthread_attr_init(&att);
    int result = pthread_create(&thread1, &att, threadproc, nil);
}

