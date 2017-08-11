// MIT License
//
// Copyright 2017 Electric Imp
//
// SPDX-License-Identifier: MIT
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
// EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
// OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
// "Promise" symbol is injected dependency from ImpUnit_Promise module,
// while class being tested can be accessed from global scope as "::Promise".

@include __PATH__ + "/BaseSFFS.device.nut"

class SFFSTestCase extends BaseSffsTestCase {
    size = 0;
    sffs = null;

    // Test that all pages are free after eraseAll
    function test01_eraseAll() {
        for (local i = 0; i < this.pages; ++i) {
            hardware.spiflash.enable();
            local buffer = hardware.spiflash.read(this.start + i * 4096, 4096);
            hardware.spiflash.disable();

            local success = true;
            foreach(b in buffer) {
                success = success && (b == 0xFF);
            }

            this.assertTrue(success);
        }
    }

    // init function create FAT table in memory
    // not of flash, therefore all headers of pages should
    // be free after function call
    function test02_init() {
        return Promise(function(ok, err) {
            this.sffs.init(function(v) {
                // all pages should be empty
                local success = true;
                for (local i = 0; i < this.pages; ++i) {
                    hardware.spiflash.enable();
                    local header = hardware.spiflash.read(this.start + i * 4096, 4096);
                    hardware.spiflash.disable();
                    // Check File ID, span ID and size
                    for (local i = 0; i < 3; ++i) {
                        local w = header.readn('w');
                        success = success && (w == 0xFFFF);
                    }

                    if (!success)
                        break;
                }
                success ? ok() : err("All pages should be empty after erase and init");
            }.bindenv(this));
        }.bindenv(this));
    }

    function test03_init() {
        // create threee single page files
        createFile("tet1.txt", "payload");
        createFile("tet2.txt", "payload");
        createFile("tet3.txt", "payload");
        // check that only three pages are marked as not free
        // after init
        return Promise(function(ok, err) {
            this.sffs.init(function(v) {
                if (3 != v.len()) {
                    err("Wrong number of files on init. 3 is expected got " + v.len());
                    return;
                }
                // start calculate marked pages
                local stats = {
                    "free": 0,
                    "used": 0
                };
                // all pages should be empty
                for (local i = 0; i < this.pages; ++i) {
                    hardware.spiflash.enable();
                    local header = hardware.spiflash.read(this.start + i * 4096, 4096);
                    hardware.spiflash.disable();
                    // Check first file id only
                    (header.readn('w') == 0xFFFF ? stats.free++ : stats.used++);
                }
                if (stats.free == this.pages - 3 && stats.used == 3)
                    ok();
                else
                    err("Expected 3 used pages got " + stats.used);
            }.bindenv(this));
        }.bindenv(this));
    }

    // Check bad pages on init
    // Expected 3 used pages for 3 files
    // and 2 bad pages should not be detected as files
    function test04_init() {
        // Create 2 bad pages
        makeBadPage();
        makeBadPage();
        return Promise(function(ok, err) {
            this.sffs.init(function(v) {
                if (3 == v.len())
                    ok();
                else
                    err("Wrong number of files on init. 3 is expected got " + v.len());
            }.bindenv(this));
        }.bindenv(this));
    }
}
