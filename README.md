# SPIFlashFileSystem 3.0.0 #

The SPIFlashFileSystem library implements a basic [wear leveling](https://en.wikipedia.org/wiki/Wear_leveling) file system intended for use with SPI Flash devices, such as the built-in [**hardware.spiflash**](https://developer.electricimp.com/api/hardware/spiflash) object available on the imp003 and above, or an external SPI Flash plus the [SPIFlash library](https://github.com/electricimp/spiflash) on the imp001 and imp002.

**To include this library in your project, add** `#require "SPIFlashFileSystem.device.lib.nut:3.0.0"` **at the top of your device code.**

![Build Status](https://cse-ci.electricimp.com/app/rest/builds/buildType:(id:SPIFlashFileSystem_BuildAndTest)/statusIcon)

## Library Classes ##

The SPIFlashFileSystem consists of three classes:

- [SPIFlashFileSystem](#spiflashfilesystem-usage) &mdash; The main programming interface for the file system.
- [SPIFlashFileSystem.File](#spiflashfilesystemfile-usage) &mdash; An object representing an open file that you can use to read, write, etc.
- [SPIFlashFileSystem.FAT](#spiflashfilesystemfat-usage) &mdash; The File Allocation Table (not used by the application developer).

### Overview Of The File System ###

The SPIFlashFileSystem (SFFS) divides the flash into 64KB blocks and 4KB sectors. The SPI flash must have at least one block allocated for the file system, and start and end bytes must be on block boundaries.

Files are written to pages that are one sector is size (4KB). Pages include a six-byte header containing a two-byte unique file ID (indicating the file that the page belongs to), a two-byte span ID (what order the pages of a particular file should be read in) and a two-byte length.

If the page is the first span of a file, it will contain an additional byte to denote the length of the filename, followed by the filename itself. It will also contain four bytes which record the file creation timestamp as a 32-bit integer.

Pages can’t be shared by files, meaning that the smallest amount of space a file can occupy is 4KB.

#### An Example File ####

Let’s look at how the SFFS stores file information and data. In this example we are going to create a file called `"test.txt"` that contains 6232 bytes of assorted data, though we don’t actually care about what the data looks like.

The file will be broken into two pages, each 4096 bytes is size. Both pages will contain six bytes of header information:

- Two bytes for the file ID.
- Two bytes for the span ID.
- Two bytes for the length of the data in the span/page.

The first span will also contain:

- Four bytes to record the creation timestamp.
- One byte to denote the length of the filename.
- The filename.

After we’ve written the header information, we fill the remainder of the span with the file’s data. We will use all of the available storage in the first span, but only the first 2150 bytes of the second span. The remaining 1946 bytes in the second span will be unusable (as pages cannot be shared by multiple files).

Because each sector contains a file ID and a span ID, the sectors can be located anywhere in the allocated SPI Flash, and likely will not be adjacent to one another (as part of the effort to wear-level the flash).

#### First Sector ####

| Byte | Data | Notes |
| --- | --- | --- |
| `0x0000` | `0x01` | Low Byte of **FileID** word |
| `0x0001` | `0x00` | High Byte of **FileID** word |
| `0x0002` | `0x01` | Low Byte of **SpanID** word |
| `0x0003` | `0x00` | High Byte of **SpanID** word |
| `0x0004` | `0xF0` | Low Byte of **length of data** in this span/sector |
| `0x0005` | `0x0F` | High Byte of **length of data** in this span/sector |
| `0x0006` | `0x56` | First Byte of **Creation time** |
| `0x0007` | `0xA8` | Second Byte of **Creation time** |
| `0x0008` | `0x76` | Third Byte of **Creation time** |
| `0x0009` | `0x47` | Fourth Byte of **Creation time** |
| `0x000A` | `0x08` | **Length of file name** |
| `0x000B` | `0x74` | t |
| `0x000C` | `0x65` | e |
| `0x000D` | `0x73` | s |
| `0x000E` | `0x74` | t |
| `0x000F` | `0x2e` | . |
| `0x0010` | `0x74` | t |
| `0x0011` | `0x78` | x |
| `0x0012` | `0x74` | t |
| `0x0013` | data | **File Data** (byte 1) |
| ... | data | **File Data** (bytes 2 - 4079) |
| `0x1000` | data | **File Data** (byte 4080) |

#### Second Sector ####

| Byte | Data | Notes |
| --- | --- | --- |
| `0x0000` | `0x01` | Low Byte of **FileID** word |
| `0x0001` | `0x00` | High Byte of **FileID** word |
| `0x0002` | `0x02` | Low Byte of **SpanID** word |
| `0x0003` | `0x00` | High Byte of **SpanID** word |
| `0x0004` | `0x66` | Low Byte of **length of data** in this span/sector |
| `0x0005` | `0x08` | High Byte of **length of data** in this span/sector |
| `0x0006` | data | **File Data** (byte 4081) |
| ... | data | **File Data** (bytes 4082 - 6230) |
| `0x084e` | data | **File Data** (byte 6231) |
| `0x084f` | `0xFF` | **Unusable** |
| ... | `0xFF` | **Unusable** |
| `0x1000` | `0xFF` | **Unusable** |

### Garbage Collection ###

When the SFFS deletes a file, it simply marks all of the pages the file was using as erased. In order to use those pages again in the future, we first need erase the sectors that the file used. This is done automatically through a process called garbage collection.

Each time a file is closed or erased, the SFFS determines whether or not it needs to run the garbage collector. It does this by comparing the number of free pages to the value of *autoGcThreshold*, which can be set with the [*setAutoGc()*](#setautogcnumpages) method.

## SPIFlashFileSystem Usage ##

### Constructor: SPIFlashFileSystem(*[start, end, spiflash]*)

The SPIFlashFileSystem constructor allows you to specify the start and end bytes of the file system in the SPIFlash, as well as an optional SPIFlash object (if you are not using the built in [**hardware.spiflash**](https://developer.electricimp.com/api/hardware/spiflash) object).

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *start* | Integer | No | The address of the file system’s first byte. Default: `0x0000` |
| *end* | Integer | No | The address of the file system’s last byte. Default: set according to the size of the flash |
| *spiflash* | Object | No | A class instance representing your SPI flash hardware. Default: the imp API [**hardware.spiflash**](https://developer.electricimp.com/api/hardware/spiflash) object |

**Note** The start and end values **must** be on block boundaries (`0x010000`, `0x020000` etc.), otherwise a `SPIFLASHFILESYSTEM_ERROR.INVALID_SPIFLASH_ADDRESS` error will be thrown.

#### Example: imp003 And Above ####

```squirrel
#require "SPIFlashFileSystem.device.lib.nut:3.0.0"

// Allocate the first 2MB to the file system
sffs <- SPIFlashFileSystem(0x000000, 0x200000);
sffs.init();
```

#### Example: imp001/imp002 ####

```squirrel
#require "SPIFlash.class.nut:1.0.1"
#require "SPIFlashFileSystem.device.lib.nut:3.0.0"

// Configure the external SPIFlash
flash <- SPIFlash(hardware.spi257, hardware.pin8);
flash.configure(30000);

// Allocate the first 2 MB to the file system
sffs <- SPIFlashFileSystem(0x000000, 0x200000, flash);
sffs.init();
```

## SPIFlashFileSystem Methods ##

### init(*[callback]*) ###

This method initializes the file system, including the creation of its file allocation table, and so must be called before invoking any other SPIFlashFileSystem method. If it is called while the file system has files open, a `SPIFLASHFILESYSTEM_ERROR.FILE_OPEN` error will be thrown.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *callback* | Function | No | A function called upon completion of the initialization process. It has one parameter of its own which receives an array: a list of files currently stored within the SPI flash. See [**File Records**](#file-records) for details of each record in the array |

#### File Records ####

Each file record passed into the optional callback is a table with the following keys:

| Key | Type | Description |
| --- | --- | --- |
| *id* | Integer | The file’s identifier |
| *fname* | String | The file’s name |
| *size* | Integer | The file’s size in bytes |
| *created* | Integer | A timestamp indicating the date and time of the file’s creation |

#### Return Value ####

Nothing.

#### Example ####

```squirrel
// Allocate the first 2MB to the file system
sffs <- SPIFlashFileSystem(0x000000, 0x200000);

// Initialize the file system FIRST
sffs.init(function(files) {
    // Log how many files we found
    server.log(format("Found %d files", files.len()));

    // Log all the information returned about each file:
    foreach(file in files) {
        server.log(format("  %d: %s (%d bytes)", file.id, file.fname, file.size));
    }
});
```

### dimensions() ###

This method provides information about the file system.

#### Return Value ####

Table &mdash; File system information with the following keys:

| Key | Description |
| --- | --- |
| *size* | The file system size in bytes |
| *len* | The size of the file system |
| *start* | The address of the first byte of SPI flash assigned to the file system |
| *end* | The address of the last byte of SPI flash assigned to the file system |
| *pages* | The number of pages available in the file system |

#### Example ####

```squirrel
local d = sffs.dimensions();
server.log("The file system contains" + d.pages + " pages");
```

### getFreeSpace() ###

This method provides an estimate of the free space available in the file system. Smaller files have more overhead than larger files so it is impossible to know exactly how much space is free.

#### Return Value ####

Table &mdash; The file system information with the following keys:

| Key | Description |
| --- | --- |
| *free* | The estimated free space in bytes |
| *freeable* | The estimated space in bytes that may be freed through further garbage collection |

### getFileList(*[orderByDate]*) ###

This method provides file information identical to that passed into the [*init()*](#initcallback) callback.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *orderByDate* | Bool | No | Should the file list be sorted into date order. Default: `false` |

#### Return Value ####

Array &mdash; A list of [file records](#file-records).

#### Example ####

```squirrel
local files = sffs.getFileList();
foreach(file in files) {
    server.log("id: " + file.id);
    server.log("fname: " + file.fname);
    server.log("size: " + file.size + " bytes");
}
```

### fileExists(*filename*) ###

This method indicates whether the specified file is present in the file system.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *filename* | String | Yes | The name of a file |

#### Return Value ####

Bool &mdash; Whether the named file exists in the file system (`true`) or not (`false`).

#### Example ####

```squirrel
if (!(sffs.fileExists("firstRun.txt")) {
    // Create the firstRun file
    sffs.open("firstRun.txt", "w").close();
    server.log("This is the first time running this code. \"firstRun.txt\" created.");
} else {
    server.log("Found \"firstRun.txt\"");
}
```

### isFileOpen(*filename*) ###

This method indicates whether the specified file is currently open.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *filename* | String | Yes | The name of a file |

#### Return Value ####

Bool &mdash; Whether the named file is open (`true`) or not (`false`).

### fileSize(*filename*) ###

This method indicates the size of the specified file’s data in bytes. It does **not** include the file’s header information or the amount of unusable space at the end of a page/sector. For example, if we created a file and wrote `hello!` to it, *fileSize()* would return `6`, but the file would actually take up 4096 bytes in our file system, as that is the smallest page we can write to.

Please see [**Overview Of The File System**](#overview-of-the-file-system) for more information.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *filename* | String | Yes | The name of a file |

#### Return Value ####

Integer &mdash; the size of the named file’s data payload.

#### Example ####

```squirrel
local filename = "HelloWorld.txt";
server.log(filename + " is " + sffs.fileSize(filename) + " bytes long");
```

### created(*fileRef*) ###

This method retrieves the creation timestamp for a specified file reference.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *fileRef* | String or integer | Yes | Either a filename (string) or a unique file ID (integer) |

#### Return Value ####

Integer &mdash; the file’s 32-bit creation timestamp.

#### Example ####

```squirrel
// Get creation date by file name
sffs.created("file.txt");

// Get creation date by ID
sffs.created(5);
```

### open(*filename, mode*) ###

This method opens the specified file with read permissions, or creates a new file.

If you attempt to open a non-existent file in reading mode, a `SPIFLASHFILESYSTEM_ERROR.FILE_NOT_FOUND` error will be thrown.

If you attempt to open an existing file in write (ie. create) mode, a `SPIFLASHFILESYSTEM_ERROR.FILE_EXISTS` error will be thrown.

If you attempt to open a file with a value of *mode* other than `"r"` or `"w"`, a `SPIFLASHFILESYSTEM_ERROR.UNKNOWN_MODE` error will be thrown.

When you create a file, it will be empty of data. While empty, it will be stored in cache only and will not be available after the next reboot. Close the file to persist it:

```squirrel
// Create an empty file
sffs.open("filename.txt", "w").close();
```

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *filename* | String | Yes | The name of a file |
| *mode* | String | Yes | How the file should be opened: `"r"` (for reading) or `"w"` (for writing, ie. file creation) |

#### Return Value ####

[SPIFlashFileSystem.File](#spiflashfilesystemfile-usage) instance &mdash; the opened file.

#### Example ####

```squirrel
// Create a file called HelloWorld.txt
local file = sffs.open("HelloWorld.txt", "w");
file.write("hello!");
file.close();

// Open HelloWorld.txt and log the contents:
file = sffs.open("HelloWorld.txt", "r");
local data = file.read();
server.log(data);
file.close();
```

### eraseFile(*filename*) ###

This method marks a single file as erased. However, the file’s data will not be erased until the [garbage collector](#garbage-collection) is run.

If the method is called while the specified file is open, a `SPIFLASHFILESYSTEM_ERROR.FILE_OPEN` error will be thrown.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *filename* | String | Yes | The name of a file |

#### Return Value ####

Nothing.

#### Example ####

```squirrel
// Delete testdata.txt
sffs.eraseFile("testdata.txt");
```

### eraseFiles() ###

This method erases all of the files within the file system. It will return with an error if it is called when there are open files. The files are marked as erasable: their data will not be erased until the [garbage collector](#garbage-collection) is run.

#### Return Value ####

String &mdash; An error message, otherwise `null`.

### eraseAll() ###

This method erases the portion of the SPI Flash allocated to the file system. Unlike [*eraseFiles()*](#erasefiles), *eraseAll()* will actually trigger an impOS spiflash erasesector operation.

If the method is called while the file system has files open, a `SPIFLASHFILESYSTEM_ERROR.FILE_OPEN` error will be thrown.

#### Return Value ####

Nothing.

#### Example ####
```squirrel
// Erase all information in the file system
sffs.eraseAll();
```

### setAutoGc(*numPages*)

This method sets the *autoGcThreshold* property. The [garbage collector](#garbage-collection) will automatically run when the file system has fewer than *autoGcThreshold* pages. The default *autoGcThreshold* value is 4.

Setting *numPages* to 0 will turn off automatic garbage collection.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *numPages* | Integer | Yes | The minimum page count limit that will trigger garbage collection, or 0 to suspend garbage collection |

#### Return Value ####

Nothing.

#### Example ####

```squirrel
// Set the filesystem to free pages marked as 'erased' whenever
// there are ten or fewer free pages left in the file system.
sffs.setAutoGc(10);
```

### gc(*[numPages]*) ###

This method manually starts the garbage collection process. The SPIFlashFileSystem is designed in such a way that the auto garbage collection should be sufficient, and you should never need to call *gc()* manually.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *numPages* | Integer | No | A number of pages to be freed by garbage collection |

If the *numPages* parameter is specified, the garbage collector will free up to *numPages* pages and return when it completes. This is what happens when the garbage collector runs because the file system needs a page and none are free.

If the *numPages* parameter is omitted, the garbage collector will run asynchronously in the background This is what happens when the garbage collector runs because free pages drops below the value of *autoGcThreshold*.

#### Return Value ####

Nothing.

## SPIFlashFileSystem.File Usage ##

A SPIFlashFileSystem.File object is returned by the SPIFlashFileSystem instance each time a file is opened. Typically, you will not need to instantiate SPIFlashFileSystem.File objects yourself.

The SPIFlashFileSystem.File object acts as a stream, with an internal read/write pointer which can be manipulated with a variety of methods in the SPIFlashFileSystem.File class.

### Constructor: SPIFlashFileSystem.File(*filesystem, fileId, fileIndex, filename, mode*)

The constructor creates a file record.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *filesystem* | Integer | Yes | The current [SPIFlashFileSystem](#spiflashfilesystem-usage) instance |
| *fileId* | Integer | Yes | The file’s unique ID |
| *fileIndex* | Integer | Yes | The index of the file in the internal record of open files |
| *filename* | String | Yes | The current file’s name |
| *mode* | String | Yes | The file’s access mode: `"r"` (read) or `"w"` (write) |

## SPIFlashFileSystem.File Methods ##

### seek(*position*) ###

This method moves the file pointer to the specified location within the file.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *position* | Integer | Yes | An index within the file data |

#### Return Value ####

Nothing.

#### Example ####

```squirrel
// Read the last byte of a file
file <- sffs.open("HelloWorld.txt", "r");
file.seek(file.len() - 1);
lastByte <- file.read(1);
```

### tell() ###

This method gets the current location of the file pointer.

#### Return Value ####

Integer &mdash; The current pointer index within the file data.

### eof() ###

This method indicates whether the file pointer is at the end of the file.

#### Return Value ####

Bool &mdash; `true` if the file pointer is at the end of the file, otherwise `false`.

#### Example ####

```squirrel
// Read a file 1-byte at a time and look for 0xFF
file <- sffs.open("HelloWorld.txt", "r");
while (!file.eof()) {
    local b = file.read(1);
    if (b == 0xFF) {
        server.log("Found 0xFF at " + b.tell());
        break;
    }
}
```

### len() ###

This method gets the current size of the file data.

#### Return Value ####

Integer &mdash; the file size in bytes.

#### Example ####

```squirrel
// Read and log the length of a file
file <- sffs.open("HelloWorld.txt", "r");
server.log(file.len());
```

### read(*[length]*) ###

This method gets data from the file, starting at the current file pointer, and returns it as a blob. If the optional *length* parameter is specified, that many bytes will be read, otherwise *read()* will read and return the remainder of the file.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *length* | Integer | No | The number of bytes to read |

#### Return Value ####

Blob &mdash; The file data that was read.

#### Example ####

```squirrel
// Read and log the contents of a file
file <- sffs.open("HelloWorld.txt", "r");
server.log(file.read().tostring());
```

### write(*data*) ###

This method writes a string or blob to the end of the target file’s data &mdash; provided you opened with mode `"w"`.

If you attempt to write to a file opened with mode `"r"`, a `SPIFLASHFILESYSTEM_ERROR.FILE_WRITE_R` error will be thrown.

**Note** The page header is not written to the SPI Flash until the entire page is written, or [*close()*](#close) is called.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *data* | Blob or string | Yes | The data to be written |

#### Return Value ####

Nothing.

#### Example ####

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

### created() ###

This method yields the file’s creation timestamp.

#### Return Value ####

Integer &mdash; The target file’s creation timestamp.

### close() ###

This method closes a file and writes data to the SPI Flash if required. All files that are opened should be closed, regardless of what mode they were opened in.

Please see [*write()*](#writedata) for example usage.

#### Return Value ####

Nothing.

## SPIFlashFileSystem.FAT Usage ##

A SPIFlashFileSystem.FAT object is automatically generated when the file system is initialized. It records the file allocation table (FAT). You should not instantiate SPIFlashFileSystem.FAT objects yourself.

### Constructor: SPIFlashFileSystem.FAT(*filesystem[, pages]*) ###

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *filesystem* | Integer | Yes | A master [SPIFlashFileSystem](#spiflashfilesystem-usage) instance |
| *pages* | Integer | No | The number of 4KB pages the file system should contain. If no value is provided, the constructor will scan the file system for files and build an FAT from them |

## SPIFlashFileSystem.FAT Methods ##

### scan() ###

This method scans the filesystem for files and uses them to construct a file allocation table.

#### Return Value ####

Nothing.

### get(*fileRef*) ###

This method retrieves information about a specific file from the file allocation table.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *fileRef* | String or integer | Yes | Either a filename (string) or a unique file ID (integer) |

#### Return Value ####

Table &mdash; File-specific information with the following keys:

| Key | Type | Description |
| --- | --- | --- |
| *id* | Integer | The file’s ID |
| *fname* | String | The file’s name |
| *spans* | Integer | The spans of the file |
| *pages* | Array | A list of pages in which the file is stored |
| *pageCount* | Integer | The number of pages in which the file is stored |
| *sizes* | Array | A list of the sizes (in bytes) of the file chunks each page contains |
| *sizeTotal* | Integer | The total size of the file |
| *created* | Integer | A timestamp indicating the date and time of the file’s creation |

### getFileList(*[orderByDate]*) ###

This method gets an array of file information, one entry per file in the file allocation table.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *orderByDate* | Bool | No | Whether the returned files should be pre-sorted into date order. Default: `false` |

#### Return Value ####

Array &mdash; A set of [file records](#file-records).

### getFileId(*filename*) ###

This method gets the unique integer by which the specified file is referenced in the file allocation table.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *filename* | String | Yes | The file’s name |

#### Return Value ####

Integer &mdash; The file’s unique ID.

### fileExists(*fileRef*) ###

This method indicates whether the specified file is present in the file system.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *fileRef* | String or integer | Yes | Either a filename (string) or a unique file ID (integer) |

#### Return Value ####

Bool &mdash; Whether the named file exists in the file system (`true`) or not (`false`).

### getFreePage() ###

This method provides the address of a random free page in the file system. It will return an error, `SPIFLASHFILESYSTEM_ERROR.NO_FREE_SPACE`, if it is unable to do so because there is no free space left.

#### Return Value ####

Integer &mdash; The address of a random free page in the file system, or an error.

### markPage(*address, status*) ###

This method sets the status of the page at the specified address. The page’s status is set by providing one of the following values:

- *SPIFLASHFILESYSTEM_STATUS.FREE*
- *SPIFLASHFILESYSTEM_STATUS.USED*
- *SPIFLASHFILESYSTEM_STATUS.ERASED*
- *SPIFLASHFILESYSTEM_STATUS.BAD*

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *address* | Integer | Yes | Either a filename (string) or a unique file ID (integer) |
| *status* | Constant | Yes | The page’s status (see above) |

#### Return Value ####

Nothing.

### addPage(*fileId, page*) ###

This method adds the specified page to the file allocation table for the specified file.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *fileId* | Integer | Yes | The file’s ID |
| *page* | Integer | Yes | The page number |

#### Return Value ####

Nothing.

### getPageCount(*fileRef*) ###

This method yields the number of pages that the specified file comprises.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *fileRef* | String or integer | Yes | Either a filename (string) or a unique file ID (integer) |

#### Return Value ####

Integer &mdash; The number of pages holding the file.

### forEachPage(*fileRef, callback*) ###

This method iterates over each page used to record the specified file.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *fileRef* | String or integer | Yes | Either a filename (string) or a unique file ID (integer) |
| *callback* | Function | Yes | The callback executed for each page. It has a single parameter which receives the current page in the iteration |

#### Return Value ####

Nothing.

### pagesOrderedBySpan(*pages*) ###

This method takes a set of pages and returns them in span order.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *pages* | Array of integers | Yes | The pages to be ordered |

#### Return Value ####

Array &mdash; The pages in span order.

### addSizeToLastSpan(*fileId, bytes*) ###

This method updates the size of the last span in a file.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *fileId* | Integer | Yes | The file’s ID |
| *bytes* | Integer | Yes | The new size in bytes |

#### Return Value ####

Nothing.

### set(*fileId, file*) ###

This method sets the span for the file specified by its ID.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *fileId* | Integer | Yes | The file’s ID |
| *file* | [SPIFlashFileSystem.File](#spiflashfilesystemfile-usage) instance  | Yes | The object representing the file |

#### Return Value ####

Nothing.

### removeFile(*filename*)

This method removes the specified file from the file allocation table, ie. it deletes the file.

#### Parameters ####

| Parameter | Type | Required? | Description |
| --- | --- | --- | --- |
| *filename* | String | Yes | The file’s name |

#### Return Value ####

Nothing.

### getSectorMap() ###

This method returns the file allocation table’s sector map.

#### Return Value ####

Blob &mdash; the map.

### getStats() ###

This method provides the number of pages in the file system in each of the [four status categories](#markpageaddress-status).

#### Return Value ####

Table &mdash; The information with the keys *free*, *used*, *erased* and *bad*. Each key’s value is an integer: the number of pages in the file system with that status.

### describe() ###

This method is intended to assist with debugging: it provides a readout in the impCentral log of the current number of files in the file allocation table, and lists each file by name, the number of pages it spans and its total size.

#### Return Value ####

Nothing.

## Testing ##

Tests can be run with the *impt* command line tool. Update the *deviceGroupId* in the test configuration file (`.impt.test`) with the ID of a device group in your account. Log in to your account, and run the following command to run tests:

```bash
impt test run
```

### Hardware ###

The provided tests require an [imp003 Breakout Board](https://developer.electricimp.com/hardware/resources/reference-designs/imp003breakout/) or [imp003 Evaluation Board](https://developer.electricimp.com/hardware/imp003evb/). Any other boards with imp003 and above containing SPI flash with available user space may work too.

## To Do ##

- Add *start* and *end* parameters to *seek()* as per the [Squirrel Blob obect](https://developer.electricimp.com/squirrel/blob/seek).
- Add an append mode (`"a"`) to *open()*.
- Add an optional asynchronous version of *_scan()* which throws a ‘ready’ event when fully loaded.
- Add an optional *SFFS_PAGE_SIZE* (4KB or multiples of 4KB) to reduce overhead.
- Support imp001/002 in testing.

### Contributing ###

Please make any pull requests you have to the __develop__ branch.

## License ##

This library and its classes are licensed under the [MIT License](https://github.com/electricimp/SPIFlashFileSystem/blob/master/LICENSE).
