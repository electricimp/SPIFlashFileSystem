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

class SffsLimitsVerification extends BaseSffsTestCase {
  fileNames = [];

  function setUpParameters() {
    for (local i = 1; i <= this.pages; i++) {
      local filename = "file" + i + ".txt";
      this.fileNames.push(filename);
    }
  }

  //
  // Test .fileList() limits
  //
  function test01_FileListLimit() {
    //
    // there are 16 sectors/pages by 4Kb on the 64kb flash
    // and each file is required 1 page/sector
    //
    for (local i = 1; i <= this.pages; i++) {
      // Create an empty file but it should allocate
      // one page at least
      local filename = this.fileNames[i - 1];
      createFile(filename, "Some payload");

      // check that it's listed
      local files = this.sffs.getFileList();
      this.assertEqual(i, files.len());

      // check the rest of the files data structure
      local created = files[i - 1]["created"];
      foreach(f in files)
      if (f.fname == filename)
        this.assertEqual(f.id, (1 + (i - 1) * 2));
    }
  }
  //
  // Test - no more space on flash for a new file
  // @methods: .fileList(), open(), close()
  //
  function test02_FileListFullFlash() {
    return Promise(function(ok, err) {
      imp.wakeup(2, function() {
        try {
          this.sffs.open(filename, "w").close();
          err("Expected: no mo space available exception");
        } catch (e) {
          // no more space on the flash
          ok();
        }
      }.bindenv(this));
    }.bindenv(this));
  }

  //
  // Test ordering of files with
  // maximum number of files
  // Note: there is no specified sorting method for the files
  //       with the same create time
  //
  function test03_FileListOrdering() {
    return Promise(function(ok, err) {
      imp.wakeup(2, function() {
        try {
          local files;

          // list files with alphabetic ordering by name
          files = this.sffs.getFileList( /* orderByDate=false */ );

          this.assertEqual("file1.txt", files[0].fname,
            "getFileList(false) is expected to sort files by name");

          // list files ordering by date, asc
          files = this.sffs.getFileList(true /* orderByDate=true */ );

          // Check that file list was sorted by "created"
          local created = 0;
          foreach(m in files) {
            this.assertTrue(created <= m.created,
              "getFileList(true) is expected to sort files by creation date");
            created = m.created;
          }
          ok();
        } catch (e) {
          err(e);
        }
      }.bindenv(this));
    }.bindenv(this));
  }

  //
  // Test maximum open file descriptors for reading
  // 1. Open all files descriptors
  // 2. Check that all descriptors are opened
  // 3. Close all descriptors
  // 4. Check that all descriptors are closed
  //
  function test04_multipleFilesReadDescriptors() {
    local descriptors = [];
    // Open max number of files
    foreach(filename in fileNames) {
      // open file
      descriptors.push(this.sffs.open(filename, "r"));
    }
    // check that all files are opened
    foreach(filename in fileNames) {
      // open file
      this.assertEqual(true, this.sffs.isFileOpen(filename));
    }
    // close all files descriptors
    foreach(f in descriptors)
    f.close();

    // Check that all descriptors are closed correctly
    foreach(filename in fileNames) {
      // open file
      this.assertEqual(false, this.sffs.isFileOpen(filename));
    }
  }

  //
  // Test .eraseFile()
  // Test erase files one by one
  //
  function test05_EraseFile() {
    foreach(filename in fileNames) {
      this.sffs.eraseFile(filename);
      this.assertEqual(false, this.sffs.fileExists(filename));
    }

    // check that there no file on the FS
    local files = this.sffs.getFileList();
    this.assertEqual(0, files.len());
  }
}
