//
//  FreeTheSandbox.h
//  Odyssey
//
//  Created by master on 2021/2/7.
//  Copyright © 2021 coolstar. All rights reserved.
//

#ifndef FreeTheSandbox_h
#define FreeTheSandbox_h

#include <stdio.h>

mach_port_t retrieve_tfp0();

uint64_t getallproc(mach_port_t tfp0);

#endif /* FreeTheSandbox_h */
