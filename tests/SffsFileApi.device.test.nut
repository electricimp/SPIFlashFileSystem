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

const MAX_SIZE_FILE_FILENAME = "max.txt";

class SffsFileApi extends BaseSffsTestCase {

    buffer = null;
    iterations = 0;
    maxHeaderSize = 0;

    function setUpParameters() {
        // payload buffer for tests
        buffer = "0123456789012345678901234567890123456789";
        // max iterations to ocupay all pages by a single file
        iterations = pages * SPIFLASHFILESYSTEM_SIZE.SECTOR / buffer.len() - 10;
        maxHeaderSize = SPIFLASHFILESYSTEM_SIZE.HEADER +
            SPIFLASHFILESYSTEM_SIZE.TIMESTAMP;
    }

        //
        // Check that max size file
        function test01_writeMaxPagesFile() {
            info("here");
            info(sffs._collecting);
            info(sffs._openFiles);
            local file = sffs.open(MAX_SIZE_FILE_FILENAME, "w");

            for (local i = 0; i < iterations; ++i)
                file.write(buffer);
            // Check that all sectors are used
            local space = sffs.getFreeSpace();
            assertTrue(space.free + space.freeable < SPIFLASHFILESYSTEM_SIZE.SECTOR);
            file.close();
            // Check that file size is correct
            assertEqual(iterations * buffer.len(),
                sffs.fileSize(MAX_SIZE_FILE_FILENAME));
        }

        function test02_maxFileSizeReading() {
            local file = sffs.open(MAX_SIZE_FILE_FILENAME, "r");
            // check that file has an expected max size
            assertEqual(iterations * buffer.len(), file.len());

            // Read and check all written payload data
            for (local i = 0; i < iterations; i += 10) {
                local payload = file.read(buffer.len());
                assertDeepEqual(buffer, payload.readstring(buffer.len()));
            }
            // all file data readed the position should be EOF
            assertTrue(file.tell() <= file.len());
            file.close();
        }

        //
        // Seek through the file randomly and check payload value
        function test03_maxFileSizeSeeking() {
            local file = sffs.open(MAX_SIZE_FILE_FILENAME, "r");
            local buffer = "0123456789012345678901234567890123456789";
            local iterations = pages * SPIFLASHFILESYSTEM_SIZE.SECTOR / buffer.len() - 10;
            // random seek
            for (local i = 0; i < iterations; i += 10) {
                local randSeek = math.rand() % iterations;
                randSeek = randSeek * buffer.len();
                file.seek(randSeek);
                assertEqual(randSeek, file.tell());
                local payload = file.read(buffer.len());
                assertEqual(buffer, payload.readstring(buffer.len()));
                assertEqual(randSeek + buffer.len(), file.tell());
            }
            // move pointer to the end of file
            file.seek(iterations * buffer.len())
            // all file data readed the position should be EOF
            assertTrue(file.eof());
            // Check tell at the end of file
            assertEqual(file.tell(), sffs.fileSize(MAX_SIZE_FILE_FILENAME));

            // check seek and tell at file start position
            file.seek(0);
            assertEqual(file.tell(), 0);
            file.close();
        }

    // seek, tell eof during file writing
    function test04_writeFileAndSeek() {
        // remove all files from the previous tests
        sffs.eraseFiles();
        // open file for write and seek
        local file = sffs.open("test.txt", "w");
        file.write(buffer);
        // tell return the read-pointer
        // therefore it should be zero for a newly
        // created file
        assertEqual(0, file.tell());
        local payload = file.read(buffer.len());
        assertEqual(buffer.len(), file.tell());
        assertEqual(file.eof(), true);
        file.seek(0);
        assertEqual(file.tell(), 0);
        file.write(buffer);
        file.seek(file.len());
        assertTrue(file.eof());
        assertEqual(file.tell(), buffer.len() * 2);
        file.seek(file.len() - 1);
        assertTrue(!file.eof());

        file.close();
        // there no way to read data from closed file
        _checkApiExceptions(file);
    }


    // seek, tell eof after file close
    function test05_fileClose() {
        local file = sffs.open("test.txt", "r");
        file.close();
        _checkApiExceptions(file);
    }

    //
    // helper method to avoid code duplication
    // for write and read use-cases
    function _checkApiExceptions(file) {
        // there no way to perform operations with closed file
        try {
          file.tell();
          assertTrue(false, "Exception expected");
        } catch (e) {
          // do nothing, expected behavior
        }

        try {
          file.seek(0);
          assertTrue(false, "Exception expected");
        } catch (e) {
          // do nothing, expected behavior
        }

        try {
          file.created();
          assertTrue(false, "Exception expected");
        } catch (e) {
          // do nothing, expected behavior
        }

        try {
          file.eof();
          assertTrue(false, "Exception expected");
        } catch (e) {
          // do nothing, expected behavior
        }

        try {
          file.read(buffer.len());
          assertTrue(false, "Exception expected");
        } catch (e) {
          // do nothing, expected behavior
        }

        try {
          file.write(buffer);
          assertTrue(false, "Exception expected");
        } catch (e) {
          // do nothing, expected behavior
        }
    }

    //
    // concurrent access to the last available free or erazed page
    //
    // what should happen when there is only one free
    // page left but we are writing 2 file which need
    // a new free page?
    function test06_concurentAccessToTheLastFreePage() {
        sffs.eraseFiles();
        for (local i = 0; i < pages - 3; ++i)
            createFile("file" + i + ".txt", "some payload");
        local stats = sffs._fat.getStats();
        // expecting that only 3 pages are available
        assertEqual(3, stats.free + stats.erased);
        //
        // Length of the filenames are different to prevent
        // writing of the same payload at the same
        // address
        local filename = "test2.txt";
        local file1 = sffs.open("test1_diff.txt", "w");
        local file2 = sffs.open(filename, "w");
        // each file has heard therefore it is enough
        // to write page size payload to each file
        // to create an concurent access use-case
        for (local i = 0; i < SPIFLASHFILESYSTEM_SIZE.SECTOR / buffer.len(); ++i) {
            file1.write(buffer);
            // an attemption to request next sector
            try {
                file2.write(buffer);
            } catch (e) {
                local expectedSize = SPIFLASHFILESYSTEM_SIZE.SECTOR -
                    maxHeaderSize - filename.len() + 1;
                // Trying to write more data then available space
                assertTrue((i + 1) * buffer.len() > expectedSize);
                // Check that number of written data less then available space
                assertTrue(file2.len() < expectedSize);
            }
        }
        file1.close();
        file2.close();

        // Check filesize after the previous test which
        // should be finished with exception
        local fs1 = sffs.fileSize("test1_diff.txt");
        local fs2 = sffs.fileSize("test2.txt");
        // expecting that first file catched free pages
        // but second one failed with it
        assertTrue(fs1 > fs2);
    }

    // check that seel of one file
    // doesn't affect seek method of another file
    function test07_multipleFilesSeek() {
        local file1 = sffs.open("test1_diff.txt", "r");
        local file2 = sffs.open("test2.txt", "r");
        for (local i = 0; i < 10; ++i) {
            local s1 = math.rand() % file1.len();
            file1.seek(s1);
            local s2 = math.rand() % file2.len();
            file2.seek(s2);
            assertEqual(s1, file1.tell());
            assertEqual(s2, file2.tell());
        }
        // Test eof dependency too
        local eofState = file2.eof();
        file1.seek(file1.len());
        assertEqual(eofState, file2.eof());
        file1.seek(0);
        assertEqual(eofState, file2.eof());
        // Close
        file1.close();
        file2.close();
    }

    // Test reading data at the eof
    function test08_eofRead() {
        local file = sffs.open("test1_diff.txt", "r");
        // seek to the eof
        file.seek(file.len());
        local payload = file.read(100);
        assertEqual(0, payload.len(), "Expected an empty payload");
        file.close();
    }

    // Test seek over the eof
    function test09_eofSeek() {
        local file = sffs.open("test1_diff.txt", "r");
        // seek eof + 10
        try {
            file.seek(file.len() + 10);
            assertTrue(false, "Exception expected on invalid paramter.");
        } catch(e) {
            // Expected exception
        }
        // seek to the end of file
        local payload = file.seek(file.len()).read(10);
        assertEqual(0, payload.len(), "Unexpected payload length at the EOF");
        file.close();
    }

    // Empty file's seek and tell and eof
    function test10_emptyFile() {
        // erase all files on FS
        sffs.eraseFiles();
        // create an empty file without any payload
        createFile("test1.txt");
        local file = sffs.open("test1.txt", "r");
        assertEqual(0, file.tell());
        assertEqual(true, file.eof());
        local seekPass = false;
        try {
            // it should be possible to seek at the same position
            file.seek(0);
            seekPass = true;
            // check that possition is correct
            assertEqual(0, file.tell());
            // this seek should throw an exception
            file.seek(1);
        } catch (e) {
            assertEqual(seekPass, true,
                "Expected that it is possible to seek on 0 for an empty file");
        }
        file.close();
    }
}
