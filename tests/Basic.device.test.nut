/**
  * This test case expects Amy board with 4-mbit flash chip
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
     * Test
     */
    function test1_FileListEmpty() {
        // chekc that nothing is listed yet
        local files = this.sffs.getFileList();
        this.assertTrue(type(files) == "array");
        this.assertEqual(0, files.len());
    }

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
     * Erase flash
     */
    function tearDown() {
        this.sffs.eraseAll();
        return "Erased flash";
    }
}