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

const ONE_KB_IN_BYTES = 1024;

// Base class for the SFFS test cases
// to share common functionality
class BaseSffsTestCase extends ImpTestCase {

    size = 0;
    sffs = null;
    pages = 0;
    start = 0;

    //
    // Initialization of the SpiFlashFileSystem library
    //    - create an SpiFlashFileSystem class object
    //    - erase all SPI flash data
    //    - initialize a new FAT block
    function setUp() {
        return Promise(function(ok, err) {
            // check that we're on    003+

            assertTrue("spiflash" in hardware, "imp003 and above is expected");

            // get actual flash size
            hardware.spiflash.enable();
            size = hardware.spiflash.size();
            hardware.spiflash.disable();
            // number of the available pages
            pages = size / SPIFLASHFILESYSTEM_SECTOR_SIZE;

            // init sffs
            sffs = SPIFlashFileSystem(0, size);
            sffs.eraseAll();
            sffs.init(function(v) {
                start = sffs.dimensions().start;

                ok("Have "
                   + (size.tofloat() / ONE_KB_IN_BYTES)
                   + "KB of flash available");

                setUpParameters();

            }.bindenv(this));

        }.bindenv(this));
    }

    //
    // Stub method to overwite in the inherited class
    //
    function setUpParameters() {
        // Empty
    }

    //
    // Create an empty file or file with payload
    //
    function createFile(filename, payload = null) {
        local file = sffs.open(filename, "w");
        if (payload)
            file.write(payload);
        file.close();
    }

    //
    // Make a bad page on flash by addr
    // if addr is null use any free page
    //
    function makeBadPage(addr = null) {
        local page = (addr == null ? sffs._fat.getFreePage() : addr);
        local header = blob(SPIFLASHFILESYSTEM_HEADER_SIZE);
        header.writen(0, 'w'); // id is 0
        header.writen(0, 'w'); // span is 0
        header.writen(123, 'w'); // size is not null

        sffs._enable();
        // Erase the page headers
        local res = sffs._flash.write(page, header, SPIFLASHFILESYSTEM_SPIFLASH_VERIFY);
        sffs._disable();
    }

    //
    // Erase flash on test case completion
    //
    function tearDown() {
        sffs.eraseAll();
        return "Flash erased";
    }
}
