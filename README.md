# SPIFlashFileSystem 0.2.0

The SPIFlashFileSystem (SFFS) library implements a basic [wear leveling](https://en.wikipedia.org/wiki/Wear_leveling) file system intended for use with SPI Flash devices (using either the built-in [hardware.spiflash](https://electricimp.com/docs/api/hardware/spiflash) object on imp003+, or an external SPI Flash plus the [SPIFlash library](https://github.com/electricimp/spiflash) on the imp001 and imp002).

**To add this library to your project, add `#require "SPIFlashFileSystem.class.nut:0.2.0"`` to the top of your device code.**

You can view the library’s source code on [GitHub](https://github.com/electricimp/spiflashfilesystem/tree/v0.2.0).

## Overview of the File System

The SFFS divides the flash into 64K blocks, and 4K sectors; and the SPI flash must have at least 1 block allocated for the file system, and start and end bytes must be on block boundaries.

Files are writen to pages that are 1 sector large (4K), and include a 6 byte header containing a 2-byte FileID (what file that page belongs to), a 2-byte SpanID (what order the pages of a particular file should be read in), and a 2-byte length. Additionally, if the page is the first span of a file, it will contain an additional byte to denote the length of the filename, followed by the filename itself.

Pages cannot be shared amongst multiple files, meaning that the smallest amount of space a file can occupy is 4K.

### Example File

Let's look at how the SPIFlashFileSystem stores file information and data. In this example we are going to create a file called "test.txt" that contains 6232 bytes of assorted data (we don't actually care about what the data looks like).

The file will be broken into two pages, each 4096 bytes large. Both pages will contain 6-bytes of header information:

- 2-bytes for the FileID
- 2-bytes for the SpanID
- 2-bytes for the length of the data in the span/page

The first span will *also* contain an additional byte to denote the length of the filename, followed by the filename itself.

After we've written the header information, we fill the remainder of the span with the file's data. We will use all of the available storage in the first span, but only the first 2150 bytes of the second span. The remaining 1946 bytes in the second span will be unusable (as pages cannot be shared amongst multiple files).

Because each sector contains a FileID and SpanID, the sectors can be anywhere in the allocated SPI Flash, and likely will not be adjacent to one another (as part of the effort to wear level the flash).

**First Sector**:

| byte   | data | notes|
| ------ | ---- | ---- |
| 0x0000 | 0x01 | Low Byte of **FileID** word |
| 0x0001 | 0x00 | High Byte of **FileID** word |
| 0x0002 | 0x01 | Low Byte of **SpanID** word |
| 0x0003 | 0x00 | High Byte of **SpanID** word |
| 0x0004 | 0xF0 | Low Byte of **length of data** in this span/sector |
| 0x0005 | 0x0F | High Byte of **length of data** in this span/sector |
| 0x0006 | 0x08 | **Length of file name** |
| 0x0007 | 0x74 | t |
| 0x0008 | 0x65 | e |
| 0x0009 | 0x73 | s |
| 0x000A | 0x74 | t |
| 0x000B | 0x2e | . |
| 0x000C | 0x74 | t |
| 0x000D | 0x78 | x |
| 0x000E | 0x74 | t |
| 0x000F | data | **File Data** (byte 1) |
| ...    | data | **File Data** (bytes 2 - 4079) |
| 0x1000 | data | **File Data** (byte 4080) |

**Second Sector**:

| byte   | data | notes|
| ------ | ---- | ---- |
| 0x0000 | 0x01 | Low Byte of **FileID** word |
| 0x0001 | 0x00 | High Byte of **FileID** word |
| 0x0002 | 0x02 | Low Byte of **SpanID** word |
| 0x0003 | 0x00 | High Byte of **SpanID** word |
| 0x0004 | 0x66 | Low Byte of **length of data** in this span/sector |
| 0x0005 | 0x08 | High Byte of **length of data** in this span/sector |
| 0x0006 | data | **File Data** (byte 4081) |
| ...    | data | **File Data** (bytes 4082 - 6230) |
| 0x084e | data | **File Data** (byte 6231) |
| 0x084f | 0xFF | **Unusable** |
| ...    | 0xFF | **Unusable** |
| 0x1000 | 0xFF | **Unusable** |

## Library Classes

The SPIFlashFileSystem consists of three classes:

- [SPIFlashFileSystem](#spiflashfilesystem) - The main programming interface for the filesystem.
- [SPIFlashFileSystem.File](#spiflashfilesystemfile) - An object representing an open file that you can use to read, write, etc.
- SPIFlashFileSystem.FAT - The File Allocation Table (not used by application developer).

# SPIFlashFileSystem

### Constructor: SPIFlashFileSystem(*[start, end, spiflash]*)

The SPIFlashFileSystem constructor allows you to specify the start and end bytes of the file system in the SPIFlash, as well as an optional SPIFlash object (if you are not using the built in `hardware.spiflash` object).

The start and end values **must** be on block boundaries (0x010000, 0x020000, ...), otherwise a `SPIFlashFileSystem.ERR_INVALID_SPIFLASH_ADDRESS` error will be thrown.

#### imp003+
```squirrel
#require "SPIFlashFileSystem.class.nut:0.2.0"

// Allocate the first 2 MB to the file system
sffs <- SPIFlashFileSystem(0x000000, 0x200000);
```

#### imp001 / imp002
```squirrel
#require "SPIFlash.class.nut:1.0.1"
#require "SPIFlashFileSystem.class.nut:0.2.0"

// Configure the external SPIFlash
flash <- SPIFlash(hardware.spi257, hardware.pin8);
flash.configure(30000);

// Allocate the first 2 MB to the file system
sffs <- SPIFlashFileSystem(0x000000, 0x200000, flash);
```

## Class Methods

### init(*[callback]*)

The *init* method initializes the FAT, and must be called before invoking other SPIFlashFileSystem methods. The init method takes an optional callback method with 1 parameter, an array of files:

```squirrel
#require "SPIFlashFileSystem.class.nut:0.2.0"

// Allocate the first 2 MB to the file system
sffs <- SPIFlashFileSystem(0x000000, 0x200000);
sffs.init(function(files) {
    // Log how many files we found
    server.log(format("Found %d files", files.len()));

    // Log all the information returned about each file:
    foreach(file in files) {
        server.log(format("  %d: %s (%d bytes)", file.id, file.fname, file.size));
    }
});
```

If the *init* method is called while the filesystem has files open, a `SPIFlashFileSystem.ERR_OPEN_FILE` error will be thrown.

### getFileList()

The *getFileList* returns an array of file information identical to that passed into the *init* callback:

```squirrel
local files = sffs.getFileList();
foreach(file in files) {
    server.log("id: " + file.id);
    server.log("fname: " + file.fname);
    server.log("size: " + file.size + " bytes");
}
```

### fileExists(*filename*)

Returns whether or not a specified file exists.

```squirrel
if (!(sffs.fileExists("firstRun.txt")) {
    // Create the firstRun file
    sffs.open("firstRun.txt", "w");
    sffs.close();

    server.log("This is the first time running this code");
} else {
    server.log("Found firstRun.txt");
}
```

### fileSize(*filename*)

Returns the size of a files data in bytes.

**NOTE**: The *fileSize* method returns the size of a file's data, and does not include the file's header information, or unusable space at the end of a page/sector. For example, if we created a file and wrote "hello!" to it, *fileSize* would return `6`, but the file would actually take up 4096 bytes in our filesystem, as that is the smallest page we can write to. See [Overview of the File System](#overview-of-the-file-system) for more information.

```squirrel
local filename = "HelloWorld.txt";
server.log(filename + " is " + sffs.fileSize(filename) + " bytes long");
```

## isFileOpen(*filename*)

Returns whether or not the specified file is currently open.

### open(*filename, mode*)

The *open* method opens the specified file with read (`mode = "r"`) or write (`mode = "w"`) permissions and returns a [SPIFlashFileSystem.File](#spiflashfilesystem-file) object.

```squirrel
// Create a file called HelloWorld.txt
local file = null;

file = sffs.open("HelloWorld.txt", "w");
file.write("hello!");
file.close();

// Open HelloWorld.txt and log the contents:
file = sffs.open("HelloWorld.txt", "r");
local data = file.read();
server.log(data);
```

If you attempt to open a non-existant file with `mode = "r"`, a `SPIFlashFileSystem.ERR_FILE_NOT_FOUND` error will be thrown.

If you attempt to open an existing file with `mode = "w"`, a `SPIFlashFileSystem.ERR_FILE_EXISTS` error will be thrown.

If you attempt to open a file with a mode other than `"r"` or `"w"` a `SPIFlashFileSystem.ERR_UNKNOWN_MODE` error will be thrown.

### eraseAll()

The *eraseAll* method erases the portion of the SPI Flash allocated to the filesystem.

```squirrel
// Erase all information in the filesystem
sffs.eraseAll();
```

If the *eraseAll* method is called while the filesystem has files open, a `SPIFlashFileSystem.ERR_OPEN_FILE` error will be thrown.

### eraseFile(*filename*)

The *eraseFile* method marks a single file as erased. The file's data will not be erased until the [garbage collector](#garbage-collection) is run.

```squirrel
// delete testdata.txt
sffs.removeFile("testdata.txt");
```

If the *eraseFile* method is called while the specified file is open, a `SPIFlashFileSystem.ERR_OPEN_FILE` error will be thrown.

## Garbage Collection

When the SPIFlashFileSystem deletes a file, it simply marks all of the pages the file was using as erased. In order to use those pages again in the future, we first need erase the sectors that the file used. This is done automatically through a process called garbage collection.

Each time a file is closed, or erased the SPIFlashFileSystem determins whether or not it needs to run the Garbage Collector. It does this by comparing the number of free pages to the *autoGcThreshold*, which can be set with [setAutoGc](#setautogcnumpages) method.

### setAutoGc(*numPages*)

The *setAutoGc* method sets the autoGcThresgold (default = 4). The garbage collector will automatically run when the filesystem has fewer *autoGcThreshold*

Setting *numPages* to 0 will turn off automatic garbage collection.

```squirrel
// The the filesystem to free pages marked as 'erased' whenever
// there are 10 or fewer free pages left in the file system.
sffs.setAutoGc(10);
```

### gc(*[numPages]*)

The *gc* method manually starts the garbage collection process. The SPIFlashFileSystem is designed in such a way that the auto garbage collection *should* be sufficient, and you should never need to manually call the *gc()* method.

If the *numPages* parameter is specified, the garbage collector will free up to *numPages* pages, and return when it completes (this is what happens when the garbage collector runs because the filesystem needs a page and none are free). If the *numPages* parameter is ommited, the garbage collector will run asynchronously in the background (this is what happens when the garbage collector runs because free pages drops below the autoGcThreshold).

## SPIFlashFileSystem.File

A *File* object is returned from the SPIFlashFileSystem each time a file is opened. The *File* object acts as a stream, with an internal pointer, which can be manipulated with a variety of methods in the File class.

## Class Methods

### seek(*pos*)

Moves the file pointer to a specific location in the file.

```squirrel
// Read the last byte of a file
file <- sffs.open("HelloWorld.txt", "r");
file.seek(file.len()-1);
lastByte <- file.read(1);
```

### tell()

Returns the current location of the file pointer.

### eof()

Returns `true` if the file pointer is at the end of the file,  and returns `false` otherwise.

```squirrel
// Read a file 1-byte at a time and look for 0xFF
file <- sffs.open("HelloWorld.txt", "r");
while(!file.eof()) {
    local b = file.read(1);
    if (b == 0xFF) {
        server.log("Found 0xFF at " + b.tell());
        break;
    }
}
```

### len()

Returns the current size of the file data.

```squirrel
// Read and log the length of a file
file <- sffs.open("HelloWorld.txt", "r");
server.log(file.size());
```

### read(*[length]*)

Reads information from the file and returns it as a blob, starting at the current file pointer. If a *length* parameter is specified, that many bytes will be read, otherwise the read method will read and return the remained of the file.

```squirrel
// Read and log the contents of a file
file <- sffs.open("HelloWorld.txt", "r");
server.log(file.read().tostring());
```

### write(*data*)

Writes a string or blob to the end of a file's data opened with mode "w" (if you attempt to write to a file opened with mode "r" a `SPIFlashFileSystem.ERR_WRITE_R_FILE` error will be thrown).

**NOTE**: The page header is not written to the SPI Flash until the entire page is written, or the [close](#close) method is called.

In the following example, we download a file in chunks from the agent:

```squirrel
file <- sffs.open("HelloWorld.txt", "w");

// Write some data to the file
// We can call write() as many times as desired
file.write("Hello");
file.write(" ");
file.write("World!");

file.close();
```

### close()

The *close* method closes a file, and writes data to the SPI Flash if required. All files that are opened should be closed (regardless of what mode they were opened in).

*See [write()](#writedata) for sample usage.*

# TODO:
- seek() from start, end, and current. See the [Squirrel documentation](https://electricimp.com/docs/squirrel/blob/seek/)
- append mode ("a") in open()
- Optional asynch version of _scan() which throws a "ready" event when fully loaded
- Optional SFFS_PAGE_SIZE (4k or multiples of)

# License

The SPIFlash class is licensed under [MIT License](https://github.com/electricimp/spiflashfilesystem/tree/master/LICENSE).
