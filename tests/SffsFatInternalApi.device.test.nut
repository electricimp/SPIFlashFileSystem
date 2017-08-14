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

class SffsFatInternalApi extends BaseSffsTestCase {
    _stats = null;
    // extra parameters for test purpose
    function setUpParameters() {
        _stats = {
            "bad": 0,
            "used": 0,
            "free": pages,
            "erased": 0
        };
    }

    //
    // Check constructor on a newly created FS
    //
    function test01_constructor() {
        // create a new FAT
        local fat = SPIFlashFileSystem.FAT(sffs, pages);

        // Check that all blocks are free
        assertDeepEqual(fat.getStats(), _stats);

        fat = SPIFlashFileSystem.FAT(sffs);
        // FAT constructor without pages parameter
        // should preform SCAN of the FS
        assertDeepEqual(fat.getStats(), _stats);
    }

    //
    // Constructor doesn't perform SCAN
    // if the "pages" argument provided
    //
    function test02_constructor() {
        createFile("test1.txt", "NOT EMPTY PAYLOAD");
        // Create a new FAT over an existing FS
        local fat = SPIFlashFileSystem.FAT(sffs, pages);

        // Assume that all blocks are free
        // because of second parameter provided to the constructor
        assertDeepEqual(fat.getStats(), _stats);
    }

    // FAT constructor without pages parameter
    // should preform SCAN of the FS
    function test03_constructor() {
        _stats.free -= 1;
        _stats.used += 1;

        local fat = SPIFlashFileSystem.FAT(sffs);
        assertDeepEqual(fat.getStats(), _stats);
    }

    //
    // Check that constructor does not recover
    // deleted files
    // Note: sffs.fat object
    function test04_constructor() {
        sffs.eraseFile("test1.txt");
        _stats.used -= 1;
        _stats.erased += 1;

        local fat = SPIFlashFileSystem.FAT(sffs);
        assertDeepEqual(fat.getStats(), _stats);
    }

    function test05_scan() {
        createFile("test1.txt", "NOT EMPTY PAYLOAD");
        createFile("test2.txt", "NOT EMPTY PAYLOAD");

        sffs._fat.scan();
        _stats.used += 2;
        _stats.free -= 2;
        // Total:
        // 2 used pages
        // 1 erased page
        assertDeepEqual(sffs._fat.getStats(), _stats);
    }

    function test06_scanBadPage() {
        // this mehod creates BAD pages on flash
        makeBadPage();

        _stats.bad += 1; // only one page was damaged
        _stats.free -= 1;
        sffs._fat.scan();
        assertDeepEqual(_stats, sffs._fat.getStats());
    }

    function test07_get() {
        local file = sffs._fat.get("test2.txt");
        // it should be the same file
        assertDeepEqual(file, sffs._fat.get(file.id));
    }

    //
    // Test that get throw ERR_FILE_NOT_FOUND exception
    //
    function test08_get_throw() {
        return Promise(function(ok, err) {
            imp.wakeup(2, function() {
                try {
                    local f = sffs._fat.get("file0.txt");
                    err("Expected file not found exception.");
                } catch (e) {
                    ok();
                }
            }.bindenv(this));
        }.bindenv(this));
    }

    //
    // Note: FAT.getFileList method covered by SFFS.getFileList
    //

    //
    // Search file ID by name:
    // 1. successful search
    // 2. throw ERR_FILE_NOT_FOUND
    function test09_getFileId() {
        local id = sffs._fat.getFileId("test1.txt")
        assertEqual(true, id >= 0);

        return Promise(function(ok, err) {
            imp.wakeup(2, function() {
                try {
                    local id = sffs._fat.get("file0.txt");
                    err("Expected file not found exception.");
                } catch (e) {
                    ok();
                }
            }.bindenv(this));
        }.bindenv(this));
    }

    //
    // Note: FAT.fileExists method covered by SFFS.fileExists tests
    //

    // Note: get free page is based on random page selection
    //             algorithm, therefore it could return a different
    //             values on each call.
    //             There is no page holding/reservation via this
    //             method.
    //
    function test10_getFreePage() {
        local dim = sffs.dimensions();
        local page = sffs._fat.getFreePage();
        // test that page in an available flash memory range
        assertEqual(true, page >= dim.start && page < dim.end);

        // Mark all pages as used to get ERR_NO_FREE_SPACE exception
        return Promise(function(ok, err) {
            imp.wakeup(2, function() {
                try {
                    local page = sffs._fat.getFreePage();
                    while (page >= 0) {
                        sffs._fat.markPage(page, SPIFLASHFILESYSTEM_STATUS_USED);
                        page = sffs._fat.getFreePage();
                    }
                    err("Expected no free space exception.");
                } catch (e) {
                    ok();
                }
            }.bindenv(this));
        }.bindenv(this));
    }

    //
    // Check that there is no problems to make a transition
    // from each pages state to another one
    // Note: current implementaion of the markPage doesn't have
    //             state tracker for the transition from BAD->free
    //             FREE->ERASED etc...
    //             The purpose of this test is to catch if such
    //             functionality will appear in the future
    //
    function test11_markPage() {
        sffs.eraseAll();
        local addr = sffs._fat.getFreePage();
        return Promise(function(ok, err) {
            imp.wakeup(2, function() {
                try {
                    local flags = [SPIFLASHFILESYSTEM_STATUS_FREE,
                        SPIFLASHFILESYSTEM_STATUS_ERASED,
                        SPIFLASHFILESYSTEM_STATUS_USED,
                        SPIFLASHFILESYSTEM_STATUS_BAD
                    ];
                    for (local i = 0; i < flags.len(); ++i) {
                        for (local j = 0; j < flags.len(); ++j) {
                            sffs._fat.markPage(addr, flags[i]);
                            sffs._fat.markPage(addr, flags[j]);
                        }
                    }
                    ok();
                } catch (e) {
                    err(e, "No exceptions expected. Please add testcase for markPage.");
                }
            }.bindenv(this));
        }.bindenv(this));
    }

    //
    // Create a very long file
    // which consists of multiple pages
    // but do not write a real data
    //
    function test12_addPage() {
        // make an empty FS
        sffs.eraseAll();
        // reset an expected stats value
        _stats = {
            "bad": 0,
            "used": 0,
            "free": pages,
            "erased": 0
        };
        // open file for writing
        local filename = "test3.txt";
        local file = sffs.open(filename, "w");

        // Create file for all 64Kb
        for (local i = 1; i <= pages; ++i) {
            local page = sffs._fat.getFreePage();
            sffs._fat.addPage(filename, page);
            // addPage doesn't mark page ad used
            // therefore we can get the same free page again and again
            // to prevent it let's mark it as used
            sffs._fat.markPage(page, SPIFLASHFILESYSTEM_STATUS_USED);
            assertEqual(sffs._fat.getPageCount(filename), i);
            sffs._fat.addSizeToLastSpan(filename, 123);
        }
        // close and remove file
        file.close();
        _stats = {
            "bad": 0,
            "used": pages,
            "free": 0,
            "erased": 0
        };
        // All blocks are used
        assertDeepEqual(sffs._fat.getStats(), _stats);

        sffs.eraseAll();
    }

    //
    // Note: page order was implemented via 2-3 extra copy operations
    //             but it is not so critical for a performance because sorting
    //                should happen in scope of one file
    //
    function test13_pageOrderBySpan() {
        // create one 64kb file
        local file = sffs.open("test1.txt", "w");
        local buffer = "0123456789012345678901234567890123456789";
        for (local i = 0; i < (size / buffer.len() - 5); ++i)
            file.write(buffer);

        local ps = sffs._fat.get("test1.txt").pages;

        file.close();

        // double check that file has correct size
        assertEqual(pages, ps.len() / 2);

        local testPages = [];
        // Check foreach page implementation
        sffs._fat.forEachPage("test1.txt", function(p) {
            testPages.push(p);
        });

        local cachedFileId = 0;
        local cachedSpanId = 0;
        // Check that all pages are sorted correctly
        foreach (p in testPages) {
            // read header of the page
            hardware.spiflash.enable();
            local buffer = hardware.spiflash.read(p, 4);
            hardware.spiflash.disable();

            local fileId = buffer.readn('w');
            local spanId = buffer.readn('w');
            // Check that file id is the same for all pages
            assertTrue(cachedFileId == 0 || cachedFileId == fileId);
            cachedFileId = fileId;
            // check that span id is increasing
            assertEqual(true, spanId >= cachedSpanId);
            cachedSpanId = spanId;
        }
    }

    //
    // Helper debug method for debuggin current tests
    //
    function debugPrintFSDetails() {
        sffs._enable();

        // Scan the headers of each page, working out what is in each
        for (local p = 0; p < pages; p++) {
            local page = dim.start + (p * SPIFLASHFILESYSTEM_PAGE_SIZE);
            local pageData = sffs._readPage(page, false);
            info("ID: " + pageData.id + " SPAN: " + pageData.span +
                " SIZE: " + pageData.size + " NAME: " + pageData.fname);
        }
        sffs._disable();
    }
}
