// MIT License
//
// Copyright 2017-19 Electric Imp
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

@include __PATH__ + "/BaseSFFS.device.nut"

class SffsMarkedBlocks extends BaseSffsTestCase {
    _stats = null;

    function checkStats(stats) {
        local s = sffs._fat.getStats();
        assertDeepEqual(stats, s);
    }

    function test01_afterErase() {
        _stats = {
            "bad": 0,
            "used": 0,
            "free": pages,
            "erased": 0
        };
        checkStats(_stats);
    }

    function test02_usedPages() {
        for (local i = 1; i <= pages; ++i) {
            // Each file should be place into one page and
            // page should be marked as used
            createFile("file_" + i + ".txt", "Some payload");

            // Check that number of free pages was changed
            _stats.used += 1;
            _stats.free -= 1;
            checkStats(_stats);
        }
    }

    function test03_usedPages() {
        for (local i = 1; i <= pages; ++i) {
            // Each file should free one page and mark it as erased
            sffs.eraseFile("file_" + i + ".txt");

            // Check that number of free pages was changed
            _stats.erased += 1;
            _stats.used -= 1;
            checkStats(_stats);
        }
    }

    function test04_onePageGarbageCollection() {
        sffs.gc(1);
        _stats.free += 1;
        _stats.erased -= 1;
        checkStats(_stats);
    }

    function test05_reuseOfFreeSpace() {
        createFile("file_1.txt", "some payload");

        _stats.used += 1;
        _stats.free -= 1;
        checkStats(_stats);
    }

    // Check GC behavior on all "erased"-marked
    // pages with threshold one
    function test06_autoGarbageCollection() {
        sffs.setAutoGc(1);
        createFile("file_2.txt", "some payload");

        // GC should clean 2 pages
        // one for a new file and one for future
        _stats.used += 1;
        _stats.free += 1
        _stats.erased -= 2;
        checkStats(_stats);
    }

    //
    // Check use-case when newly recorded file
    // takes 2 pages and auto gc free
    // 2*threshold pages
    function test07_autoGarbageCollection2() {
        sffs.setAutoGc(1);
        local file = sffs.open("file_3.txt", "w");
        // write more then 4KB data
        for (local i = 0; i < 200; ++i)
            file.write("01234567890123456789012340");
        file.close();

        _stats.used += 2;
        _stats.erased -= 2;
        checkStats(_stats);
    }

    // Check that erase method does not
    // mark free sectors
    //
    // Note: AutoGC do nothing on file erase
    //
    function test08_eraseFiles() {
        sffs.eraseFiles();

        _stats.used = 0;
        _stats.erased = pages - _stats.free;
        checkStats(_stats);
    }

    //
    // precondition - there are number of blocks to erase with AutoGC
    //
    function test09_noMoreBlocksToEraseWithAutoGC() {
        sffs.setAutoGc(1);

        for (local i = 1; i <= pages; ++i) {
            // Each file should be place into one page and
            // page should be marked as used
            createFile("file_" + i + ".txt", "Some payload");
            _stats.used += 1;

            // Check that number of erased and free pages
            // on each iteration
            if (_stats.free == 0) {
                if (_stats.erased < 2) {
                    _stats.free = 0;
                    _stats.erased = 0;
                } else {
                    _stats.erased -= 2;
                    _stats.free = 1;
                }
            } else {
                _stats.free -= 1;
            }

            checkStats(_stats);
        }
    }

    //
    // Recover to the initial state
    //
    function test10_eraseAll() {
        sffs.eraseAll();
        _stats = {
            "bad": 0,
            "used": 0,
            "free": pages,
            "erased": 0
        };
        checkStats(_stats);
    }
}
