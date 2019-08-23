// MIT License
//
// Copyright 2016-2017 Electric Imp
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

    //
    // Test .fileList() with empty FAT
    //
    function test01_FileListWhenEmpty() {
        // chekc that nothing is listed yet
        local files = sffs.getFileList();
        assertTrue(type(files) == "array");
        assertEqual(0, files.len());
    }

    //
    //Test .fileList() after cteating a file
    //
    function test02_FileListNonEmpty() {
        // create an empty file
        createFile("file1.txt");

        // check that it's listed
        local files = sffs.getFileList();
        assertTrue(type(files) == "array");
        assertEqual(1, files.len());

        // check creation date
        assertClose(time(), files[0].created, 1);

        // check the rest of the files data structure
        files[0]["created"] <- 0;
        assertDeepEqual([{
            "size": 0,
            "id": 1,
            "created": 0,
            "fname": "file1.txt"
        }], files);
    }

    //
    //Test ordering of files in .fileList()
    //
    function test03_FileListOrdering() {
        return Promise(function(ok, err) {
            imp.wakeup(2, function() {
                try {
                    // creat file a with later date, but alphabetically
                    // preceedeing already existing file1.txt
                    sffs.open("file0.txt", "w").close();

                    local files;

                    // list filres with ordering by name, adc
                    files = sffs.getFileList( /* orderByDate=false */ );
                    if ("file0.txt" != files[0].fname) {
                        err("getFileList(false) is expected to sort files by name");
                        return;
                    }

                    // list files ordering by date, asc
                    files = sffs.getFileList(true /* orderByDate=true */ );
                    if ("file1.txt" != files[0].fname) {
                        err("getFileList(true) is expected to sort files by creation date");
                        return;
                    }
                    ok();

                } catch (e) {
                    err(e);
                }
            }.bindenv(this));
        }.bindenv(this));
    }

    //
    //Test .fileExists()
    //
    function test04_fileExists() {
        assertEqual(true, sffs.fileExists("file1.txt"));
        assertEqual(false, sffs.fileExists("nonexisting-file.txt"));
        assertEqual(false, sffs.fileExists(""));
        assertEqual(false, sffs.fileExists("\0"));
    }

    //
    //Test .fileSize()
    //
    function test05_fileSize() {
        // empty file
        assertEqual(0, sffs.fileSize("file1.txt"));

        // nonexistent file
        assertThrowsError(function() {
            sffs.fileSize("nonexisting-file.txt");
        }, this);

        // create file
        local f = sffs.open("file2.txt", "w");
        f.write(blob(1    ))
        f.close();

        // check existing file size
        assertEqual(1    , sffs.fileSize("file2.txt"));
    }

    //
    //Test .isFileOpen()
    //
    function test06_isFileOpen() {
        // existing closed file
        assertEqual(false, sffs.isFileOpen("file1.txt"));

        // non-existing file
        assertThrowsError(function() {
            sffs.isFileOpen("nonexisting-file.txt");
        }, this);

        // open file
        local f = sffs.open("file2.txt", "r");
        assertEqual(true, sffs.isFileOpen("file2.txt"));
        f.close();
    }

    //
    //Test .open()
    //
    function test07_Open() {
        local f;

        // existing file for reading
        f = sffs.open("file1.txt", "r");
        assertTrue(f instanceof SPIFlashFileSystem.File);
        f.close();

        // non-existing file for reading
        assertThrowsError(function() {
            sffs.open("nonexisting-file.txt", "r");
        }, this);

        // existing file for writing
        assertThrowsError(function() {
            sffs.open("file1.txt", "w");
        }, this);

        // non-existing file for writing
        f = sffs.open("file3.txt", "w");
        assertTrue(f instanceof SPIFlashFileSystem.File);
        assertTrue(sffs.isFileOpen("file3.txt"));
        f.close();
    }

    //
    //Test .eraseFile()
    //
    function test08_EraseFile() {
        // existing file
        sffs.eraseFile("file1.txt");
        assertEqual(false, sffs.fileExists("file1.txt"));

        // non-existing file
        assertThrowsError(function() {
            sffs.eraseFile("nonexisting-file.txt");
        }, this);

        // existing open file
        local f = sffs.open("file2.txt", "r");
        assertThrowsError(@() sffs.eraseFile("file2.txt"), this);
        assertEqual(true, sffs.fileExists("file2.txt"));
        f.close();
    }

    //
    //Test .eraseFiles()
    //
    function test09_EraseFiles() {
        local files;

        // check that there are files
        files = sffs.getFileList();
        assertGreater(files.len(), 0);

        // erase all files
        sffs.eraseFiles();

        // check that tere are no files
        files = sffs.getFileList();
        assertEqual(0, files.len());
    }

    //
    //Test .dimensions()
    //
    function test10_Dimensions() {
        assertDeepEqual({
                "start": 0,
                "size": size,
                "end": size,
                "len": size,
                "pages": size / SPIFLASHFILESYSTEM_SIZE.PAGE
            },
            sffs.dimensions()
        );
    }

    //
    //Test .created()
    //
    function test11_Created() {
        // test that created date on newly created file == time()
        sffs.open("file4.txt", "w").close();
        assertClose(time(), sffs.created("file4.txt"), 1);
    }

    //
    // Helper method to test filename input parameters
    //
    function _openTest(filename) {
        try {
            sffs.open(filename, "w");
            assertTrue(false, "An SPIFLASHFILESYSTEM_ERROR.INVALID_FILENAME ex")
        } catch (e) {
            assertEqual(SPIFLASHFILESYSTEM_ERROR.INVALID_FILENAME, e);
        }
    }

    //
    // an empty filename or nul
    // max+1 length of filename
    //
    function test12_fileOpen() {
        _openTest(null);
        _openTest("");
        // create 256+ filename
        local filename = "01234567890";
        while (filename.len() <= 256)
            filename += filename;
        // too long filename
        _openTest(filename);
    }
}
