/**
  * Currently this test case expects Amy board with 4-mbit flash chip
  * todo: use SPIFlash library for 001/002
  */

class BasicTestCase extends ImpTestCase {

    size = 0;
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
            this.size = hardware.spiflash.size();
            hardware.spiflash.disable();

            // init sffs
            this.sffs = SPIFlashFileSystem(0, size);
            this.sffs.eraseAll();
            this.sffs.init(function (v) {
                ok("Have " + this.size.tofloat() / 1024 + "KB of flash available")
            }.bindenv(this));

        }.bindenv(this));
    }

    /**
     * Test .fileList() with empty FAT
     */
    function test01_FileListWhenEmpty() {
        // chekc that nothing is listed yet
        local files = this.sffs.getFileList();
        this.assertTrue(type(files) == "array");
        this.assertEqual(0, files.len());
    }

    /**
     * Test .fileList() after cteating a file
     */
    function test02_FileListNonEmpty() {
        // create empty file
        this.sffs.open("file1.txt", "w").close();

        // check that it's listed
        local files = this.sffs.getFileList();
        this.assertTrue(type(files) == "array");
        this.assertEqual(1, files.len());

        // check creation date
        this.assertClose(time(), files[0].created, 1);

        // check the rest of the files data structure
        files[0]["created"] <- 0;
        this.assertDeepEqual([{"size":0,"id":1,"created":0,"fname":"file1.txt"}], files);
    }

    /**
     * Test .fileExists()
     */
    function test03_fileExists() {
        this.assertEqual(true, this.sffs.fileExists("file1.txt"));
        this.assertEqual(false, this.sffs.fileExists("nonexisting-file.txt"));
        this.assertEqual(false, this.sffs.fileExists(""));
        this.assertEqual(false, this.sffs.fileExists("\0"));
    }

    /**
     * Test .fileSize()
     */
    function test04_fileSize() {
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
    function test05_isFileOpen() {
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
    function test06_Open() {
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
    function test07_EraseFile() {
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
    function test08_EraseFiles() {
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
     * Test .dimensions()
     */
    function test09_Dimensions() {
        this.assertDeepEqual(
            {
                "start": 0,
                "size": this.size,
                "end": this.size,
                "len": this.size,
                "pages": this.size / SPIFLASHFILESYSTEM_PAGE_SIZE
            },
            this.sffs.dimensions()
        );
    }

    /**
     * Test .created()
     */
    function test10_Created() {
        // test that created date on newly created file == time()
        this.sffs.open("file4.txt", "w").close();
        this.assertClose(time(), this.sffs.created("file4.txt"), 1);
    }

    /**
     * Erase flash
     */
    function tearDown() {
        this.sffs.eraseAll();
        this.test01_FileListWhenEmpty();
        return "Flash erased";
    }
}
