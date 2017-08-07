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

  //
  // Test .fileList() with empty FAT
  //
  function test01_FileListWhenEmpty() {
    // chekc that nothing is listed yet
    local files = this.sffs.getFileList();
    this.assertTrue(type(files) == "array");
    this.assertEqual(0, files.len());
  }

  //
  //Test .fileList() after cteating a file
  //
  function test02_FileListNonEmpty() {
    // create an empty file
    createFile("file1.txt");

    // check that it's listed
    local files = this.sffs.getFileList();
    this.assertTrue(type(files) == "array");
    this.assertEqual(1, files.len());

    // check creation date
    this.assertClose(time(), files[0].created, 1);

    // check the rest of the files data structure
    files[0]["created"] <- 0;
    this.assertDeepEqual([{
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
          this.sffs.open("file0.txt", "w").close();

          local files;

          // list filres with ordering by name, adc
          files = this.sffs.getFileList( /* orderByDate=false */ );
          this.assertEqual("file0.txt", files[0].fname, "getFileList(false) is expected to sort files by name");

          // list files ordering by date, asc
          files = this.sffs.getFileList(true /* orderByDate=true */ );
          this.assertEqual("file1.txt", files[0].fname, "getFileList(true) is expected to sort files by creation date");
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
    this.assertEqual(true, this.sffs.fileExists("file1.txt"));
    this.assertEqual(false, this.sffs.fileExists("nonexisting-file.txt"));
    this.assertEqual(false, this.sffs.fileExists(""));
    this.assertEqual(false, this.sffs.fileExists("\0"));
  }

  //
  //Test .fileSize()
  //
  function test05_fileSize() {
    // empty file
    this.assertEqual(0, this.sffs.fileSize("file1.txt"));

    // nonexistent file
    this.assertThrowsError(function() {
      this.sffs.fileSize("nonexisting-file.txt");
    }, this);

    // create file
    local f = this.sffs.open("file2.txt", "w");
    f.write(blob(100))
    f.close();

    // check existing file size
    this.assertEqual(100, this.sffs.fileSize("file2.txt"));
  }

  //
  //Test .isFileOpen()
  //
  function test06_isFileOpen() {
    // existing closed file
    this.assertEqual(false, this.sffs.isFileOpen("file1.txt"));

    // non-existing file
    this.assertThrowsError(function() {
      this.sffs.isFileOpen("nonexisting-file.txt");
    }, this);

    // open file
    local f = this.sffs.open("file2.txt", "r");
    this.assertEqual(true, this.sffs.isFileOpen("file2.txt"));
    f.close();
  }

  //
  //Test .open()
  //
  function test07_Open() {
    local f;

    // existing file for reading
    f = this.sffs.open("file1.txt", "r");
    this.assertTrue(f instanceof SPIFlashFileSystem.File);
    f.close();

    // non-existing file for reading
    this.assertThrowsError(function() {
      this.sffs.open("nonexisting-file.txt", "r");
    }, this);

    // existing file for writing
    this.assertThrowsError(function() {
      this.sffs.open("file1.txt", "w");
    }, this);

    // non-existing file for writing
    f = this.sffs.open("file3.txt", "w");
    this.assertTrue(f instanceof SPIFlashFileSystem.File);
    this.assertTrue(this.sffs.isFileOpen("file3.txt"));
    f.close();
  }

  //
  //Test .eraseFile()
  //
  function test08_EraseFile() {
    // existing file
    this.sffs.eraseFile("file1.txt");
    this.assertEqual(false, this.sffs.fileExists("file1.txt"));

    // non-existing file
    this.assertThrowsError(function() {
      this.sffs.eraseFile("nonexisting-file.txt");
    }, this);

    // existing open file
    local f = this.sffs.open("file2.txt", "r");
    this.assertThrowsError(@() this.sffs.eraseFile("file2.txt"), this);
    this.assertEqual(true, this.sffs.fileExists("file2.txt"));
    f.close();
  }

  //
  //Test .eraseFiles()
  //
  function test09_EraseFiles() {
    local files;

    // check that there are files
    files = this.sffs.getFileList();
    this.assertGreater(files.len(), 0);

    // erase all files
    this.sffs.eraseFiles();

    // check that tere are no files
    files = this.sffs.getFileList();
    this.assertEqual(0, files.len());
  }

  //
  //Test .dimensions()
  //
  function test10_Dimensions() {
    this.assertDeepEqual({
        "start": 0,
        "size": this.size,
        "end": this.size,
        "len": this.size,
        "pages": this.size / SPIFLASHFILESYSTEM_PAGE_SIZE
      },
      this.sffs.dimensions()
    );
  }

  //
  //Test .created()
  //
  function test11_Created() {
    // test that created date on newly created file == time()
    this.sffs.open("file4.txt", "w").close();
    this.assertClose(time(), this.sffs.created("file4.txt"), 1);
  }

  //
  // Helper method to test filename input parameters
  //
  function _openTest(filename) {
    try {
      sffs.open(null, "w");
      assertTrue(false, "An ERR_INVALID_FILE ex")
    } catch (e) {
      assertEqual("Invalid filename", e);
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
