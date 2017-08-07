// Copyright (c) 2016 Electric Imp
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT

// File system information
const SPIFLASHFILESYSTEM_SECTOR_SIZE = 4096;
const SPIFLASHFILESYSTEM_PAGE_SIZE = 4096;

// File information
const SPIFLASHFILESYSTEM_MAX_FNAME_SIZE = 64;
const SPIFLASHFILESYSTEM_TIMESTAMP_SIZE = 4;
const SPIFLASHFILESYSTEM_HEADER_SIZE = 6; // id (2) + span (2) + size (2)

// Statuses
const SPIFLASHFILESYSTEM_STATUS_FREE = 0x00;
const SPIFLASHFILESYSTEM_STATUS_USED = 0x01;
const SPIFLASHFILESYSTEM_STATUS_ERASED = 0x02;
const SPIFLASHFILESYSTEM_STATUS_BAD = 0x03;

const SPIFLASHFILESYSTEM_SPIFLASH_VERIFY = 1; // Don't verify = 0, Post Verify = 1, Pre Verify = 2, Pre and Post Verify = 3

class SPIFlashFileSystem {
    // Library version
    static version = [1, 2, 0];

    // Errors
    static ERR_OPEN_FILE = "Cannot perform operation with file(s) open."
    static ERR_FILE_NOT_FOUND = "The requested file does not exist."
    static ERR_FILE_EXISTS = "Cannot (w)rite to an existing file."
    static ERR_WRITE_R_FILE = "Cannot write to file with mode 'r'"
    static ERR_UNKNOWN_MODE = "Tried opening file with unknown mode."
    static ERR_VALIDATION = "Error validating SPI Flash write operation."
    static ERR_INVALID_SPIFLASH_ADDRESS = "Tried writing to an invalid location."
    static ERR_INVALID_WRITE_DATA = "Can only write blobs and strings to files."
    static ERR_NO_FREE_SPACE = "File system out of space."
    static ERR_INVALID_FILENAME = "Invalid filename";

    // Private:
    _flash = null;          // The SPI Flash object
    _size = null;           // The size of the SPI Flash
    _start = null;          // First byte of SPIFlash allocated to file system
    _end = null;            // Last byte of SPIFlash allocated to file system
    _len = null;            // Size of File System

    _pages = 0;             // Number of pages available in the File system

    _enables = 0;           // Counting semaphore for _enable/_disable

    _fat = null;            // The File Allocation Table
    _openFiles = null;      // Array of open files
    _nextFileIdx = 1;       // Next ID to use for files

    _autoGcThreshold = 4;   // If we fall below _autoGCThreshold # of free pages, we start GC
    _collecting = false;    // Flag to indicate an async gc is in progress

    // Creates Filesystem objects, but does not initialize
    constructor(start = null, end = null, flash = null) {
        // Set the SPIFlash object (hardware.spiflash, or an object with equivalent interface)
        _flash = flash ? flash : hardware.spiflash;

        // Get the size of the spiflash
        _enable();
        _size = _flash.size();
        _disable();

        // Set start/end values
        _start = start ? start : 0;
        _end = end ? end : _size;

        // Validate start/end values:

        // Start is in the SPIFlash, and on a sector boundary
        if (_start < 0 || _start >= _size || _start % SPIFLASHFILESYSTEM_SECTOR_SIZE != 0) throw ERR_INVALID_SPIFLASH_ADDRESS;
        // _end is after start, in the SPIFlash, and on a sector boundary
        if (_end <= _start || (_end - _start) > _size || _end % SPIFLASHFILESYSTEM_SECTOR_SIZE != 0) throw ERR_INVALID_SPIFLASH_ADDRESS;

        // Calculate size of file system
        _len = _end - _start;
        _pages = _len / SPIFLASHFILESYSTEM_PAGE_SIZE;

        // Initialize the filesystem
        _openFiles = {};
        _fat = SPIFlashFileSystem.FAT(this, _pages);
    }

    // Initializes File System / Builds FAT
    function init(callback = null) {
        // Make sure there aren't any open files:
        if (_openFiles.len() > 0) throw ERR_OPEN_FILE;

        // Free up some memory
        _fat = null;

        // Scan the pages for files
        _fat = SPIFlashFileSystem.FAT(this);

        // if there was no callback, we're done
        if (callback) {
            // Otherwise, invoke callback against each file
            callback(getFileList());
        }

    }

    // Erases the portion of the SPIFlash dedicated to the fs
    function eraseAll() {
        // Can't erase if there's open files?
        if (_openFiles.len() > 0) throw ERR_OPEN_FILE;

        _fat = SPIFlashFileSystem.FAT(this, _pages);

        _enable();
        for (local p = 0; p < _pages; p++) {
            local page = _start + (p * SPIFLASHFILESYSTEM_SECTOR_SIZE);
            _flash.erasesector(page);
        }
        _disable();
    }

    // Erases a single file
    function eraseFile(fname) {

        if (!_fat.fileExists(fname)) throw ERR_FILE_NOT_FOUND;
        if (isFileOpen(fname)) throw ERR_OPEN_FILE;

        // Build a blob to zero out the file
        local zeros = blob(SPIFLASHFILESYSTEM_HEADER_SIZE + SPIFLASHFILESYSTEM_TIMESTAMP_SIZE + SPIFLASHFILESYSTEM_MAX_FNAME_SIZE + 1);

        _enable();

        local pages = _fat.forEachPage(fname, function(addr) {
            // Erase the page headers
            local res = _flash.write(addr, zeros, SPIFLASHFILESYSTEM_SPIFLASH_VERIFY);
            if (res != 0) {
                _disable();
                throw ERR_VALIDATION;
            }
            // Mark the page map
            _fat.markPage(addr, SPIFLASHFILESYSTEM_STATUS_ERASED);
        }.bindenv(this));

        _disable();

        // Update the fat
        _fat.removeFile(fname);

        // Run the garbage collector if needed
        _autoGc();
    }

    // Erases all files
    function eraseFiles() {

        if (_openFiles.len() > 0) return server.error("Can't call eraseFiles() with open files");

        _enable();

        local files_to_erase = _fat.getFileList();
        foreach (file in files_to_erase) {
            eraseFile(file.fname);
        }

        _disable();

    }


    // Opens a file to (r)ead, (w)rite, or (a)ppend
    function open(fname, mode) {
    	// Validate filename
    	if (typeof fname != "string" || fname.len() == 0 || fname.len() > SPIFLASHFILESYSTEM_MAX_FNAME_SIZE) throw ERR_INVALID_FILENAME;

        // Validate operation
        if      ((mode == "r") && !_fat.fileExists(fname))  throw ERR_FILE_NOT_FOUND;
        else if ((mode == "w") && _fat.fileExists(fname))   throw ERR_FILE_EXISTS;
        else if (mode != "r" && mode != "w") throw ERR_UNKNOWN_MODE;

        // Create a new file pointer from the FAT or a new file
        local fileId = _fat.getFileId(fname);
        local fileIdx = _nextFileIdx++;
        _openFiles[fileIdx] <- fileId;

        // Return a new file object
        return SPIFlashFileSystem.File(this, fileId, fileIdx, fname, mode);
    }

    //-------------------- Utility Methods --------------------//
    // Returns an array of file objects containing: { "id": int, "fname": string, "size": int }
    // The files are order by date stamp or file name
    function getFileList(orderByDate = false) {
        return _fat.getFileList(orderByDate);
    }

    // Returns true if a file is open, false otherwise
    function isFileOpen(fname) {
        // Search through the open file table for matching ids
        local id = _fat.get(fname).id;
        foreach (ptr, fileId in _openFiles) {
            if (id == fileId) return true;
        }
        return false;
    }

    // Returns true if a file exists, false otherwise
    function fileExists(fname) {
        return _fat.fileExists(fname);
    }

    // Returns the size of a file
    function fileSize(fileRef) {
        return _fat.get(fileRef).sizeTotal;
    }

    // Returns a table with the dimensions of the File System
    function dimensions() {
        return { "size": _size, "len": _len, "start": _start, "end": _end, "pages": _pages }
    }

    // Returns the created time stamp
    function created(fileRef) {
        return _fat.get(fileRef).created;
    }

    function getFreeSpace() {

        // Smaller files have more overhead than larger files so its impossible to know exactly how much space is free.
        // This is a total guess of how much space an average sector would have for data.
        local stats = _fat.getStats();
        const page_size_guess = 4000;
        local free = stats.free * page_size_guess;
        local freeable = (stats.free + stats.erased) * page_size_guess;
        return { free = free, freeable = freeable };
    }


    //-------------------- GARBAGE COLLECTION --------------------//
    // Sets the Garbage Collection threshold
    function setAutoGc(maxPages) {
        // Override the default auto garbage collection settings
        if (maxPages != null) _autoGcThreshold = maxPages;
    }

    function gc(numPages = null) {
        // Don't auto-garbage if we're already in the process of doing so
        if (numPages == null && _collecting == true) return;

        _enable();

        // Scan the headers of each page, working out what is in each
        local collected = 0;
        local sectorMap = _fat.getSectorMap().tostring()
        local maplen = sectorMap.len();

        // Asynchronous (auto-gc)
        if (numPages == null) {
            _collecting = true;
            imp.wakeup(0, function() { _gc(sectorMap, 0); }.bindenv(this));
            return;
        }


        // Synchronous
        local firstSector = math.rand() % maplen;
        for(local sector = 0; sector < maplen; sector++) {
            // If the sector is dirty
            local thisSector = (sector + firstSector) % maplen;
            if (sectorMap[thisSector] == SPIFLASHFILESYSTEM_STATUS_ERASED || sectorMap[thisSector] == SPIFLASHFILESYSTEM_STATUS_BAD) {

                // Erase the sector and mark the map
                local addr = _start + thisSector*SPIFLASHFILESYSTEM_SECTOR_SIZE
				_enable();
                _flash.erasesector(addr);
                _fat.markPage(addr, SPIFLASHFILESYSTEM_STATUS_FREE);
				_disable();
                collected++;

                // If we've collected enough pages, we're done
                if (numPages != null && collected >= numPages) break;
            }
        }

        _disable();
    }

    // Recursive asynchronous Garbage Collections
    function _gc(sectorMap, sector, collected = 0) {
        // Base case: we're at the end
        if (sector >= sectorMap.len()) {
            _collecting = false;
            _disable();
            return;
        }

        // If the sector is dirty
        if (sectorMap[sector] == SPIFLASHFILESYSTEM_STATUS_ERASED || sectorMap[sector] == SPIFLASHFILESYSTEM_STATUS_BAD) {

            // Erase the sector and mark the map
            local addr = _start + sector*SPIFLASHFILESYSTEM_SECTOR_SIZE
            _flash.erasesector(addr);
            _fat.markPage(addr, SPIFLASHFILESYSTEM_STATUS_FREE);
            collected++;
        }

        // Collect the next dirty page
        imp.wakeup(0, function() { _gc(sectorMap, sector+1, collected); }.bindenv(this));
    }

    // Checks whether we want to Garbage Collect, and starts process if we do
    function _autoGc() {
        // Don't garbage collect if there's open file, or user has turned off gc
        if (_openFiles.len() > 0 || _autoGcThreshold <= 0) return;

        // Is it worth gc'ing? If so, start it.
        local _fatStats = _fat.getStats();
        if (!_collecting && _fatStats.free <= _autoGcThreshold && _fatStats.erased > 0) {
            gc();
        }

    }

    //-------------------- PRIVATE METHODS --------------------//
    // Closes a file, sets size, etc
    function _close(fileId, fileIdx, dirty) {
        // We have changes to write to disk
        if (dirty) {
            local file = _fat.get(fileId);

            // Write the last span's size to disk
            file.pages.seek(-2, 'e');
            local page = file.pages.readn('w') * SPIFLASHFILESYSTEM_PAGE_SIZE;

            file.sizes.seek(-2, 'e');
            local size = file.sizes.readn('w');

            _writeSize(page, size);
        }

        // Now drop the file pointer;
        delete _openFiles[fileIdx];

        // Auto garbage collect if required
        _autoGc()
    }

    // Writes a string or blob to a file
    function _write(fileId, addr, data) {
        local type = typeof data;
        if (type != "string" && type != "blob") throw ERR_INVALID_WRITE_DATA;

        // Turn strings into blobs
        if (type == "string") {
            local data_t = blob(data.len());
            data_t.writestring(data);
            data = data_t;
            data.seek(0);
        }

        // Get the file object
        local file = _fat.get(fileId);

        // Write the data to free pages, one page at a time
        local writtenToPage = 0, writtenFromData = 0;

        while (!data.eos()) {
            // If we need a new page
            if (addr % SPIFLASHFILESYSTEM_PAGE_SIZE == 0) {
                // Find and record the next page
                try {
                    addr = _fat.getFreePage();
                } catch (e) {
                    // No free pages, try garbage collection and then die if its still a problem
                    gc();
                    addr = _fat.getFreePage();
                }

                // Update file with new page in FAT
                _fat.addPage(file.id, addr)
                file.pageCount++;
                file.spans++;
            }

            // Write to the page without the size
            local info = _writePage(addr, data, file.id, file.spans, file.fname);

            // If we are in the middle of a page then add the changes
            _fat.addSizeToLastSpan(fileId, info.writtenFromData);

            // Advance the pointers/counters
            addr += info.writtenToPage;
            data.seek(info.writtenFromData, 'c')

            writtenFromData += info.writtenFromData;
            writtenToPage += info.writtenToPage;

            // Go back and write the size of the previous page
            if (addr % SPIFLASHFILESYSTEM_PAGE_SIZE == 0) {
                // if we are at the end of the page we can just write 0
                _writeSize(addr - SPIFLASHFILESYSTEM_PAGE_SIZE, 0);
            }

        }

        // Update the FAT
        _fat.set(fileId, file);

        // Return a summary of the _write action
        return { "writtenFromData": writtenFromData, "writtenToPage": writtenToPage, "addr": addr };
    }

    // Writes a single page of a file
    function _writePage(addr, data, id, span, fname, size = 0xFFFF) {
        if (addr >= _end) throw ERR_INVALID_SPIFLASH_ADDRESS;

        // Figure out how much space is left in current page
        local remInPage = SPIFLASHFILESYSTEM_PAGE_SIZE - (addr % SPIFLASHFILESYSTEM_PAGE_SIZE);
        // Figure outhow much more data we need to write
        local remInData = (data == null) ? 0 : data.len() - data.tell();

        // Track how much we wrote
        local writtenFromData = 0;  // How much of "data" we wrote
        local writtenToPage = 0;    // How much we wrote to the page (including header)

        // Mark the page as used
        _fat.markPage(addr, SPIFLASHFILESYSTEM_STATUS_USED);

        // If we're at the start of a page
        if (remInPage == SPIFLASHFILESYSTEM_PAGE_SIZE) {

            // Create and write the header
            local headerBlob = blob(SPIFLASHFILESYSTEM_HEADER_SIZE)
            headerBlob.writen(id, 'w');
            headerBlob.writen(span, 'w');
            headerBlob.writen(size, 'w');

            // If this is a zero-index page (start of file)
            if (span == 0) {
                // Write the time stamp
                headerBlob.writen(time(), 'i');
                // Truncate and write the filename
                headerBlob.writen(fname.len(), 'b');
                if (fname.len() > 0) {
                    headerBlob.writestring(fname);
                }
            }

            // write the header
            _enable();
            local res = _flash.write(addr, headerBlob, SPIFLASHFILESYSTEM_SPIFLASH_VERIFY);
            _disable();

            // Validate write
            if (res != 0) throw ERR_VALIDATION;

            // Record how much we have written
            local dataWritten = headerBlob.len();

            // Update pointer information
            addr += dataWritten;
            remInPage -= dataWritten;
            writtenToPage += dataWritten;
        }

        if (remInData > 0) {
            // Work out how much to write - the lesser of the remaining in the page and the remaining in the data
            local dataToWrite = (remInData < remInPage) ? remInData : remInPage;

            // Write the data
            _enable();
            local res = _flash.write(addr, data, SPIFLASHFILESYSTEM_SPIFLASH_VERIFY, data.tell(), data.tell() + dataToWrite);
            _disable();

            // Validate write
            if (res != 0) throw ERR_VALIDATION;

            // Update pointer information
            addr += dataToWrite;
            remInPage -= dataToWrite;
            remInData -= dataToWrite;
            writtenFromData += dataToWrite;
            writtenToPage += dataToWrite;

        }

        // Return object with summary of what we wrote
        return {
            "remInPage": remInPage,
            "remInData": remInData,
            "writtenFromData": writtenFromData,
            "writtenToPage": writtenToPage
        };
    }

    // Writes the size of a file to the header
    function _writeSize(addr, size) {
        if (addr >= _end || addr % SPIFLASHFILESYSTEM_PAGE_SIZE != 0) throw ERR_INVALID_SPIFLASH_ADDRESS;

        local headerBlob = blob(SPIFLASHFILESYSTEM_HEADER_SIZE)
        headerBlob.writen(0xFFFF, 'w'); // the id
        headerBlob.writen(0xFFFF, 'w'); // The span
        headerBlob.writen(size, 'w');

        // Write it
        _enable();
        local res = _flash.write(addr, headerBlob); // Verification will fail
        _disable();

        if (res != 0) throw ERR_FILE_EXISTS;
    }

    // Reads a file (or portion of a file)
    function _read(fileId, start, len = null) {
        // Get the file
        local file = _fat.get(fileId);

        // Create the result object
        local result = blob();

        // Fix the default length to everything
        if (len == null) len = file.sizeTotal - start;

        // find the initial address
        local next = start, togo = len, pos = 0, page = null, size = null;

        // Reset blob pointers for pages/sizes
        file.pages.seek(0);
        file.sizes.seek(0);

        // Read all the pages
        while (!file.pages.eos()) {
            page = file.pages.readn('w') * SPIFLASHFILESYSTEM_PAGE_SIZE;
            size = file.sizes.readn('w');

            if (next < pos + size) {
                // Read the data
                local data = _readPage(page, true, next - pos, togo);
                data.data.seek(0);
                result.writeblob(data.data);

                // Have we got everything?
                togo -= data.data.len();
                next += data.data.len();
                if (togo == 0) break;
            }

            // Advance pointers
            pos += size;
        }
        return result;

    }

    // Reads a single page of a file
    function _readPage(addr, readData = false, from = 0, len = null) {
        if (addr >= _end) throw ERR_INVALID_SPIFLASH_ADDRESS;

        _enable();

        // Read the header
        local headerBlob = _flash.read(addr, SPIFLASHFILESYSTEM_HEADER_SIZE + SPIFLASHFILESYSTEM_MAX_FNAME_SIZE + SPIFLASHFILESYSTEM_TIMESTAMP_SIZE + 1);

        // Parse the header
        local pageData = {
            "id":  headerBlob.readn('w'),
            "span": headerBlob.readn('w'),
            "size": headerBlob.readn('w'),
            "fname": null,
            "created": null
        };

        if (pageData.span == 0) {
            // Read the created timestamp
            pageData.created = headerBlob.readn('i');
            // Read the filename
            local fnameLen = headerBlob.readn('b');
            if (fnameLen > 0 && fnameLen <= SPIFLASHFILESYSTEM_MAX_FNAME_SIZE) {
                pageData.fname = headerBlob.readstring(fnameLen);
            }
        }

        // Correct the size
        local maxSize = SPIFLASHFILESYSTEM_PAGE_SIZE - headerBlob.tell();
        if ((pageData.span != 0xFFFF && pageData.id != 0)
           && (pageData.size == 0 || pageData.size > maxSize)) {
            pageData.size = maxSize;
        }
        pageData.eof <- headerBlob.tell() + pageData.size;

        // Read the data if required
        if (readData) {
            local dataOffset = headerBlob.tell();
            if (from + len > pageData.size) len = pageData.size - from;
            pageData.data <- _flash.read(addr + dataOffset + from, len);
        }

        _disable();

        // Check the results
        pageData.status <- SPIFLASHFILESYSTEM_STATUS_BAD;
        if (pageData.id == 0xFFFF && pageData.span == 0xFFFF && pageData.size == 0xFFFF && pageData.fname == null) {
            pageData.status = SPIFLASHFILESYSTEM_STATUS_FREE;   // Unwritten Page
        } else if (pageData.id == 0 && pageData.span == 0 && pageData.size == 0 && pageData.fname == null) {
            pageData.status = SPIFLASHFILESYSTEM_STATUS_ERASED; // Erased Page
        } else if (pageData.id > 0 && pageData.id < 0xFFFF && pageData.span == 0 && pageData.size < 0xFFFF && pageData.fname != null) {
            pageData.status = SPIFLASHFILESYSTEM_STATUS_USED;   // Header Page (span = 0)
        } else if (pageData.id > 0 && pageData.id < 0xFFFF && pageData.span > 0 && pageData.span < 0xFFFF && pageData.fname == null) {
            pageData.status = SPIFLASHFILESYSTEM_STATUS_USED;   // Normal Page
        } else {
            // NOOP - Broken Page?
        }

        return pageData;
    }

    // Methods for countin
    function _enable() {
        if (_enables++ == 0) {
            _flash.enable();
        }
    }

    function _disable() {
        if (--_enables <= 0)  {
            _enables = 0;
            _flash.disable();
        }
    }
}

class SPIFlashFileSystem.FAT {

    _filesystem = null;

    _names = null;
    _pages = null;
    _sizes = null;
    _spans = null;
    _creates = null;

    _map = null;

    _nextId = 1;

    //--------------------------------------------------------------------------
    constructor(filesystem, pages = null) {

        // Mapping of fileId to pages, sizes and spanIds
        _pages = {};
        _sizes = {};
        _spans = {};
        _creates = {};

        // Mapping of filename to fileId
        _names = {};

        // Store the parent file system object
        _filesystem = filesystem;

        if (typeof pages == "integer") {
            //  Make a new, empty page map
            _map = blob(pages);
            for (local i = 0; i < _map.len(); i++) {
                _map[i] = SPIFLASHFILESYSTEM_STATUS_FREE;
            }
        } else {
            // Build a new FAT by scanning the disk
            scan();
        }
    }


    // Scans the file system for FAT entries
    function scan() {

        local _pages_t = {};
        local _sizes_t = {};
        local dim = _filesystem.dimensions();
        _map = blob(dim.pages);

        _filesystem._enable();

        // Scan the headers of each page, working out what is in each
        for (local p = 0; p < dim.pages; p++) {

        	local page = dim.start + (p * SPIFLASHFILESYSTEM_PAGE_SIZE);
        	local header = _filesystem._readPage(page, false);

        	// Record this page's status
        	_map.writen(header.status, 'b');

        	if (header.status == SPIFLASHFILESYSTEM_STATUS_USED) {
                // Add the span to the fat
                if (!(header.id in _pages_t)) {
                    _pages_t[header.id] <- {};
                    _sizes_t[header.id] <- {};
                    _creates[header.id] <- 0;
                    _spans[header.id] <- -1;
                 }
                _pages_t[header.id][header.span] <- page;
                _sizes_t[header.id][header.span] <- header.size;
                if (header.created != null) _creates[header.id] <- header.created;
                if (header.fname != null) _names[header.fname] <- header.id;

                // Work out the highest spanId and fileId
                if (header.span > _spans[header.id]) _spans[header.id] = header.span;
                if (header.id >= _nextId) _nextId = header.id + 1;

            }
        }

        _filesystem._disable();


        // Pull the file details out and make a more efficient FAT
        foreach (fileName,fileId in _names) {

            // Save the pages as a single blob
            _pages[fileId] <- blob(_pages_t[fileId].len() * 2);
            local pages = pagesOrderedBySpan(_pages_t[fileId]);
            foreach (page in pages) {
                _pages[fileId].writen(page / SPIFLASHFILESYSTEM_PAGE_SIZE, 'w');
            }
            pages = null;

            // Save the sizes
            _sizes[fileId] <- blob(_sizes_t[fileId].len() * 2);
            local sizes = pagesOrderedBySpan(_sizes_t[fileId]);
            foreach (size in sizes) {
                _sizes[fileId].writen(size, 'w');
             }
            sizes = null;

         }
    }


    // Gets the FAT information for a specified file reference (id or name)
    function get(fileRef) {

        local fileId = null, fname = null;

        // If a filename was passed
        if (typeof fileRef == "string") {
            fname = fileRef;
            // Get the fileId
            if (fname in _names) {
                fileId = _names[fname];
            }
        } else {
            // If a fileId was passed
            fileId = fileRef;
            // Get the filename
            foreach (filename,id in _names) {
                if (fileId == id) {
                    fname = filename;
                    break;
                }
            }
        }

        // Check the file is valid
        if (fileId == null || fname == null) throw SPIFlashFileSystem.ERR_FILE_NOT_FOUND;

        // Add up the sizes
        local sizeTotal = 0, size = 0;
        _sizes[fileId].seek(0);
        while (!_sizes[fileId].eos()) {
            sizeTotal += _sizes[fileId].readn('w');
        }

        // Return the file object
        return {
            "id": fileId,
            "fname": fname,
            "spans": _spans[fileId],
            "pages": _pages[fileId],
            "pageCount": _pages[fileId].len() / 2,
            "sizes": _sizes[fileId],
            "sizeTotal": sizeTotal,
            "created": _creates[fileId]
        };

    }

    // Returns a simplified list of files for the dev to use
    function getFileList(orderByDate = false) {
        local list = [];
        foreach (fname,id in _names) {
            local file = get(fname);
            list.push({
                "id": file.id,
                "fname": file.fname,
                "size": file.sizeTotal,
                "created": file.created
            });
        }

        // Order the files
        if (orderByDate) {
            list.sort(function(a, b) { return a.created <=> b.created }.bindenv(this));
        } else {
            list.sort(function(a, b) { return a.fname <=> b.fname }.bindenv(this));
        }
        return list;
    }

    // Sets the spans array for the specified file id
    function set(fileId, file) {
        _spans[fileId] = file.spans;
    }

    // Returns the fileId for a specified filename
    // + creates file if doesn't already exist
    function getFileId(filename) {
        // Create the file if it doesn't exist
        if (!fileExists(filename)) {
            // Create a new file
            _names[filename] <- _nextId;
            _pages[_nextId] <- blob();
            _sizes[_nextId] <- blob();
            _spans[_nextId] <- -1;
            _creates[_nextId] <- time();
            _nextId = (_nextId + 1) % 65535 + 1; // 1 ... 64k-1
        }

        // Return the fileId
        return _names[filename];
    }

    // Returns true when a file exists in the FAT, false otherwise
    function fileExists(fileRef) {
        // Check the file is valid
        return ((fileRef in _pages) || (fileRef in _names));
    }

    // Returns address of a random free page (or throws error if out of space)
    function getFreePage() {
        local map = _map.tostring();

        // Find a random free page
        local randStart = math.rand() % _map.len();
        local next = map.find(SPIFLASHFILESYSTEM_STATUS_FREE.tochar(), randStart);

        // If we didn't a free page from the random midpoint, start again from the beginning
        if (next == null) {
            next = map.find(SPIFLASHFILESYSTEM_STATUS_FREE.tochar());
        }

        // If there were 0 free pages, garbage collect, and start again from the beginning
        if (next == null) {
            _filesystem.gc(2 * _filesystem._autoGcThreshold);
            next = map.find(SPIFLASHFILESYSTEM_STATUS_FREE.tochar());
        }

        // If we haven't found one after garbage collection, theow error
        if (next == null) throw SPIFlashFileSystem.ERR_NO_FREE_SPACE;

        // If we did find a page, return it
        return _filesystem.dimensions().start + (next * SPIFLASHFILESYSTEM_PAGE_SIZE);
    }

    // Updates a page to the specified status (free, used, erased, bad)
    function markPage(addr, status) {
        // Ammend the page map
        local i = (addr - _filesystem.dimensions().start) / SPIFLASHFILESYSTEM_PAGE_SIZE;
        _map[i] = status;
    }

    // Returns a reference to the sector map (_map)
    function getSectorMap() {
        return _map;
    }

    // Returns # of each type of page in fs (free, used, erased, bad)
    function getStats() {
        local stats = { "free": 0, "used": 0, "erased": 0, "bad": 0 };
        local map = _map.tostring();
        foreach (ch in map) {
            switch (ch) {
                case SPIFLASHFILESYSTEM_STATUS_FREE:   stats.free++; break;
                case SPIFLASHFILESYSTEM_STATUS_USED:   stats.used++; break;
                case SPIFLASHFILESYSTEM_STATUS_ERASED: stats.erased++; break;
                case SPIFLASHFILESYSTEM_STATUS_BAD:    stats.bad++; break;
            }
        }
        return stats;
    }

    // Adds a page to the FAT for a specified file
    function addPage(fileId, page) {
        // Append the page
        get(fileId).pages.writen(page / SPIFLASHFILESYSTEM_PAGE_SIZE, 'w')
        get(fileId).sizes.writen(0, 'w');
    }

    // Updates the size of the last span in a file
    function addSizeToLastSpan(fileId, bytes) {

        // Read the last span's size, add the value and rewrite it
        local sizes = get(fileId).sizes;
        sizes.seek(-2, 'e');
        local size = sizes.readn('w') + bytes
        sizes.seek(-2, 'e');
        sizes.writen(size, 'w');
    }

    // Returns the number of pages for a specified file
    function getPageCount(fileRef) {
        return get(fileRef).pages.len() / 2;    // Each pageId is 2 bytes
    }

    // Removes a file from the FAT
    function removeFile(fname) {
        // Check the file is valid
        if (!fileExists(fname)) throw ERR_FILE_NOT_FOUND;

        // Get the fileId
        local id = _names[fname];

        // Remove information from the FAT
        delete _names[fname];
        delete _pages[id];
        delete _sizes[id];
        delete _spans[id];
        delete _creates[id];
    }

    // Iterates over each page of the specified file, and invokes the callback
    function forEachPage(fileRef, callback) {

        // Find the pages
        local pages = get(fileRef).pages;

        // Loop through the pages, calling the callback for each one
        pages.seek(0);
        while (!pages.eos()) {
            local page = pages.readn('w') * SPIFLASHFILESYSTEM_PAGE_SIZE;
            callback(page);
        }

    }


    // Returns an array of pages ordered by the span
    function pagesOrderedBySpan(pages) {

        // Load the table contents into an array
        local interim = [];
        foreach (s,p in pages) {
            interim.push({ s = s, p = p });
        }

        // Sort the array by the span
        interim.sort(function(first, second) {
            return first.s <=> second.s;
        });

        // Write them to a final array without the key
        local result = [];
        foreach (i in interim) {
            result.push(i.p);
        }

        return result;
    }

    // Debugging function to server.log FAT information
    function describe() {
        server.log(format("FAT contained %d files", _names.len()))
        foreach (fname,id in _names) {
            server.log(format("  File: %s, spans: %d, bytes: %d", fname, getPageCount(id), get(id).sizeTotal))
        }
    }
}

class SPIFlashFileSystem.File {

    _filesystem = null;
    _fileIdx = null;
    _fileId = null;
    _fname = null;
    _mode = null;
    _pos = 0;
    _wpos = 0;
    _waddr = 0;
    _dirty = false;

    constructor(filesystem, fileId, fileIdx, fname, mode) {
        _filesystem = filesystem;
        _fileIdx = fileIdx;
        _fileId = fileId;
        _fname = fname;
        _mode = mode;
    }


    // Closes a file
    function close() {
        return _filesystem._close(_fileId, _fileIdx, _dirty);
    }

    // Sets file pointer to the specified position
    function seek(pos) {
        // Set the new pointer position
        _pos = pos;
        return this;
    }

    // Returns file pointer's current location
    function tell() {
        return _pos;
    }

    // Returns true when the file pointer is at the end of the file
    function eof() {
        return _pos >= _filesystem._fat.get(_fileId).sizeTotal;
    }

    // Returns the size of the file
    function len() {
        return _filesystem._fat.get(_fileId).sizeTotal;
    }

    // Returns the creation timestamp
    function created() {
        return _filesystem._fat.get(_fileId).created;
    }

    // Reads data from the file
    function read(len = null) {
        local data = _filesystem._read(_fileId, _pos, len);
        _pos += data.len();
        // make data blob ready to read
        data.seek(0);
        return data;
    }

    // Writes data to the file and updates the FAT
    function write(data) {
        if (_mode == "r") throw ERR_WRITE_R_FILE;
        local info = _filesystem._write(_fileId, _waddr, data);

        _wpos += info.writtenFromData;
        _waddr = info.addr;
        _dirty = true;

        return info.writtenToPage;
    }
}
