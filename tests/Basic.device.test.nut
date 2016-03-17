/**
  * Currently this test case expects Amy board with 4-mbit flash chip
  * todo: use SPIFlash library for 001/002
  */

class BasicTestCase extends ImpTestCase {

    sffs = null;

    /**
     * Init SFFS
     *  - create class
     *  - erase flash
     *  - init FAT
     */
    function setUp() {
        return Promise(function(ok, err) {
            // check that we're on  003+
            this.assertTrue("spiflash" in hardware, "imp003 and above is expected");

            // get actual flash size
            hardware.spiflash.enable();
            local size = hardware.spiflash.size();
            hardware.spiflash.disable();

            // init sffs
            this.sffs = SPIFlashFileSystem(0, size);
            this.sffs.eraseAll();
            this.sffs.init(function (v) {
                ok("Have " + size.tofloat() / 1024 + "KB of flash available")
            });

        }.bindenv(this));
    }

    /**
     * Test .fileList() with empty FAT
     */
    function test1_FileListWhenEmpty() {
        // chekc that nothing is listed yet
        local files = this.sffs.getFileList();
        this.assertTrue(type(files) == "array");
        this.assertEqual(0, files.len());
    }

    /**
     * Test .fileList() after cteating a file
     */
    function test2_FileListNonEmpty() {
        // create empty file
        this.sffs.open("file1.txt", "w").close();

        // check taht it's listed
        local files = this.sffs.getFileList();
        this.assertTrue(type(files) == "array");
        this.assertEqual(1, files.len());
        this.assertDeepEqual([{"size":0,"id":1,"created":0,"fname":"file1.txt"}], files);
    }

    /**
     * Test .fileExists()
     */
    function test3_fileExists() {
        this.assertEqual(true, this.sffs.fileExists("file1.txt"));
        this.assertEqual(false, this.sffs.fileExists("nonexisting-file.txt"));
        this.assertEqual(false, this.sffs.fileExists(""));
        this.assertEqual(false, this.sffs.fileExists("\0"));
    }

    /**
     * Test .fileSize()
     */
    function test4_fileSize() {
        // empty file
        this.assertEqual(0, this.sffs.fileSize("file1.txt"));

        // nonexistent file
        this.assertThrowsError(function () {
            this.sffs.fileSize("nonexisting-file.txt");
        }, this);

        // create file
        local f = this.sffs.open("file2.txt", "w");
        f.write(blob(100))
        f.close();

        // check existing file size
        this.assertEqual(100, this.sffs.fileSize("file2.txt"));
    }

    /**
     * Test .isFileOpen()
     */
    function test5_isFileOpen() {
        // existing closed file
        this.assertEqual(false, this.sffs.isFileOpen("file1.txt"));

        // non-existing file
        this.assertThrowsError(function () {
            this.sffs.isFileOpen("nonexisting-file.txt");
        }, this);

        // open file
        local f = this.sffs.open("file2.txt", "r");
        this.assertEqual(true, this.sffs.isFileOpen("file2.txt"));
        f.close();
    }

    /**
     * Test .open()
     */
    function test6_Open() {
        local f;

        // existing file for reading
        f = this.sffs.open("file1.txt", "r");
        this.assertTrue(f instanceof SPIFlashFileSystem.File);
        f.close();

        // non-existing file for reading
        this.assertThrowsError(function () {
            this.sffs.open("nonexisting-file.txt", "r");
        }, this);

        // existing file for writing
        this.assertThrowsError(function () {
            this.sffs.open("file1.txt", "w");
        }, this);

        // non-existing file for writing
        f = this.sffs.open("file3.txt", "w");
        this.assertTrue(f instanceof SPIFlashFileSystem.File);
        this.assertTrue(this.sffs.isFileOpen("file3.txt"));
        f.close();
    }

    /**
     * Test .eraseFile()
     */
    function test7_EraseFile() {
        // existing file
        this.sffs.eraseFile("file1.txt");
        this.assertEqual(false, this.sffs.fileExists("file1.txt"));

        // non-existing file
        this.assertThrowsError(function () {
            this.sffs.eraseFile("nonexisting-file.txt");
        }, this);

        // existing open file
        local f = this.sffs.open("file2.txt", "r");
        this.assertThrowsError(@ () this.sffs.eraseFile("file2.txt"), this);
        this.assertEqual(true, this.sffs.fileExists("file2.txt"));
        f.close();
    }

    /**
     * Test .eraseFiles()
     */
    function test8_EraseFiles() {
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

    /**
     * Erase flash
     */
    function tearDown() {
        this.sffs.eraseAll();
        this.test1_FileListWhenEmpty();
        return "Flash erased";
    }
}
