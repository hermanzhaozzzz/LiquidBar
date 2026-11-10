# Notices

LiquidBar uses the installed [liquidctl](https://github.com/liquidctl/liquidctl)
Python package at runtime. liquidctl is licensed under GPL-3.0-or-later.

The AppleSMC reader is adapted from
[Stats](https://github.com/exelban/stats/blob/master/SMC/smc.swift), copyright
Serhiy Mytrovtsiy, originally licensed under the MIT License.

The LiquidBar application icon was generated for this project with OpenAI's
image generation tooling and is distributed as part of LiquidBar under the
project license.

The DeepCool LD numeric-display protocol was implemented using the published
mapping and Rust implementation in
[Nortank12/deepcool-digital-linux](https://github.com/Nortank12/deepcool-digital-linux),
including `src/devices/ld_series.rs` (blob
`3e0b215c83a359ce00893d3bc1050dc5c1d8459b`). That project is distributed under
the GNU GPL v3. No Linux binary is bundled.

The ASUS `0b05:18f3` mainboard protocol and configuration-table layout follow
[OpenRGB's AsusAuraMainboardController](https://github.com/CalcProgrammer1/OpenRGB/blob/master/Controllers/AsusAuraUSBController/AsusAuraUSBController/AsusAuraMainboardController.cpp)
and [AsusAuraUSBController](https://github.com/CalcProgrammer1/OpenRGB/blob/master/Controllers/AsusAuraUSBController/AsusAuraUSBController/AsusAuraUSBController.cpp),
both attributed to Martin Hartl (inlart), 25 Apr 2020, in OpenRGB's source headers,
licensed GPL-2.0-or-later. LiquidBar implements the runtime USB messages and does
not bundle OpenRGB. Configuration-derived LED offsets are required on X570;
the generic liquidctl AURA driver's fixed offsets do not fit this board.

The motherboard adapter uses the documented/source-visible user-client ABI of
[trulyspinach/SMCAMDProcessor release 0.7.2](https://github.com/trulyspinach/SMCAMDProcessor/tree/0.7.2).
The kernel extension is supplied by the user and is not bundled or installed by
LiquidBar. Its BSD license is reproduced below for the interface/source reference.

BSD 3-Clause License

Copyright (c) 2020, trulyspinach
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
