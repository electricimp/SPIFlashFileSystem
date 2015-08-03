// File system information
const SFFS_BLOCK_SIZE = 65536;
const SFFS_SECTOR_SIZE = 4096;
const SFFS_PAGE_SIZE = 4096;

// File information
const SFFS_MAX_FNAME_SIZE = 20;
const SFFS_HEADER_SIZE = 6; // id (2) + span (2) + size (2)

// Statuses
const SFFS_STATUS_FREE = 0x00;
const SFFS_STATUS_USED = 0x01;
const SFFS_STATUS_ERASED = 0x02;
const SFFS_STATUS_BAD = 0x03;

// Lookup Masks
const SFFS_LOOKUP_MASK_ID = 0x7FFF;
const SFFS_LOOKUP_MASK_INDEX = 0x8000;
const SFFS_LOOKUP_FREE  = 0xFFFF;
const SFFS_LOOKUP_ERASED  = 0x0000;

// Lookup stat values
const SFFS_LOOKUP_STAT_ERASED = 0x00;
const SFFS_LOOKUP_STAT_INDEX  = 0x01;
const SFFS_LOOKUP_STAT_DATA   = 0x02;
const SFFS_LOOKUP_STAT_FREE   = 0xFF;

const SFFS_SPIFLASH_VERIFY = 1; // SPIFLASH_POSTVERIFY = 1

//==============================================================================
class SPIFlashFileSystem {
    static version = [0, 2, 0];

    static ERR_OPEN_FILE = "Cannot perform operation with file(s) open."
    static ERR_FILE_NOT_FOUND = "The requested file does not exist."

    static ERR_UNKNOWN_MODE = "Tried opening file with unknown mode."

    static ERR_VALIDATION = "Error validating SPI Flash write operation."

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

    _autoGcThreshold = 4;

    //--------------------------------------------------------------------------
    constructor(start = null, end = null, flash = null) {
        _flash = flash ? flash : hardware.spiflash;

        // Get the size of the spiflash
        _enable();
        _size = _flash.size();
        _disable();

        // Set start/end values
        _start = start ? start : 0;
        _end = end ? end : _size;

        // Validate start/end values

        // Start is in the SPIFlash, and on a sector boundary
        if (_start < 0 || _start >= _size || _start % SFFS_SECTOR_SIZE != 0) throw "Invalid start value";
        // _end is after start, in the SPIFlash, and on a sector boundary
        if (_end <= _start || _end > _size || _end - _start > _size || _end % SFFS_SECTOR_SIZE != 0) throw "Invalid end value";


        // Calculate size of file system
        _len = _end - _start;
        _pages = _len / SFFS_PAGE_SIZE;

        // Initialize the filesystem
        _openFiles = {};
        _fat = SPIFlashFileSystem.FAT(this, _pages);
    }


    //--------------------------------------------------------------------------
    function init(callback = null) {

        if (_openFiles.len() > 0) return server.error("Can't call init() with open files");

        // Free up some memory
        _fat = null;

        // Scan the pages for files
        local scan = _scan();
        _fat = SPIFlashFileSystem.FAT(this, scan.files, scan.pages);

    }

    //--------------------------------------------------------------------------
    function dimensions() {
        return { "size": _size, "len": _len, "start": _start, "end": _end }
    }


    //--------------------------------------------------------------------------
    function isFileOpen(fname) {
        // Search through the open file table for matching ids
        local id = _fat.get(fname).id;
        foreach (ptr, fileId in _openFiles) {
            if (id == fileId) return true;
        }
        return false;
    }


    //--------------------------------------------------------------------------
    function eraseFile(fname) {

        if (!_fat.fileExists(fname)) throw ERR_FILE_NOT_FOUND;
        if (isFileOpen(fname)) throw ERR_OPEN_FILE;

        _enable();

        local zeros = blob(SFFS_HEADER_SIZE + 1 + SFFS_MAX_FNAME_SIZE);

        local pages = _fat.forEachPage(fname, function(addr) {
            // Erase the page headers
            local res = _flash.write(addr, zeros, SFFS_SPIFLASH_VERIFY);
            if (res != 0) throw ERR_VALIDATION;

            // Mark the page map
            _fat.markPage(addr, SFFS_STATUS_ERASED);
        }.bindenv(this));

        _disable();

        // Update the fat
        _fat.removeFile(fname);

    }


    //--------------------------------------------------------------------------
    function eraseAll() {
        if (_openFiles.len() > 0) throw ERR_OPEN_FILE;

        _fat = SPIFlashFileSystem.FAT(this, _pages);

        _enable();
        for (local p = 0; p < _pages; p++) {
            _flash.erasesector(p * SFFS_PAGE_SIZE);
        }
        _disable();
    }


    //--------------------------------------------------------------------------
    function fileExists(fname) {
        return _fat.fileExists(fname);
    }


    //--------------------------------------------------------------------------
    function fileSize(fileRef) {
        return _fat.get(fileRef).size;
    }


    //--------------------------------------------------------------------------
    function open(fname, mode) {

        // Check the mode
        if ((mode == "r") && !_fat.fileExists(fname)) {
            throw ERR_FILE_NOT_FOUND;
        } else if ((mode == "w") && _fat.fileExists(fname)) {
            throw format("Can't open '%s' for writing, already exists", fname);
        } else if (mode != "r" && mode != "w" && mode != "a") {
            throw ERR_UNKNOWN_MODE;
        }

        // Create a new file pointer from the FAT or a new file
        local fileId = _fat.getFileId(fname);
        local fileIdx = _nextFileIdx++;
        _openFiles[fileIdx] <- fileId;

        // Return a new file object
        return SPIFlashFileSystem.File(this, fileId, fileIdx, fname, mode);

    }


    //--------------------------------------------------------------------------
    function gc() {

        _enable();

        // Scan the headers of each page, working out what is in each
        local collected = 0;
        for (local p = 0; p < _pages; p++) {

            local page = _start + (p * SFFS_PAGE_SIZE);
            local header = _readPage(page, false);
            // server.log(page + " = " + header.status.tostring())

            if (header.status == SFFS_STATUS_ERASED || header.status == SFFS_STATUS_BAD) {
                _flash.erasesector(page);
                _fat.markPage(page, SFFS_STATUS_FREE);
                collected++;
            }
        }

        _disable();

        if (collected > 0) server.log("Garbage collected " + collected + " pages");
        return collected;
    }


    //--------------------------------------------------------------------------
    function setAutoGc(maxPages) {

        // Override the default auto garbage collection settings
        if (maxPages != null) _autoGcThreshold = maxPages;

    }


    //--------------------------------------------------------------------------
    function _autoGc() {

        // Is it worth gc'ing? If so, start it.
        local _fatStats = _fat.getStats();
        if (_fatStats.free <= _autoGcThreshold && _fatStats.erased > 0) {
            server.log("Automatically starting garbage collection");
            gc();
        }

    }


    //--------------------------------------------------------------------------
    function _close(fileId, fileIdx, dirty) {

        // We have changes to write to disk
        if (dirty) {
            local file = _fat.get(fileId);

            // Write the last span's size to disk
            file.pages.seek(-2, 'e');
            local page = file.pages.readn('w') * SFFS_PAGE_SIZE;
            file.sizes.seek(-2, 'e');
            local size = file.sizes.readn('w');

            // server.log(format("The last span of file %d has size %d at addr %d", fileId, size, page))
            _writeSize(page, size);
        }

        // Now drop the file pointer;
        delete _openFiles[fileIdx];

        // Auto garbage collect if required
        if (_openFiles.len() == 0 && _autoGcThreshold != 0) _autoGc()
    }


    //--------------------------------------------------------------------------
    function _write(fileId, addr, data) {

        // Make sure we have a blob
        if (typeof data == "string") {
            local data_t = blob(data.len());
            data_t.writestring(data);
            data = data_t;
            data.seek(0);
        } else if (typeof data != "blob") {
            throw "Can only write blobs and strings";
        }

        // Work out what we know about this file
        local file = _fat.get(fileId);
        // server.log(format("Writing %d bytes to '%s' at position %d", data.len() - data.tell(), file.fname, addr));

        // Write the data to free pages, one page at a time
        local writtenToPage = 0, writtenFromData = 0;
        while (!data.eos()) {

            // If we need a new page
            if (addr % SFFS_PAGE_SIZE == 0) {

                // Find and record the next page
                try {
                    addr = _fat.getFreePage();
                } catch (e) {
                    // No free pages, try garbage collection and then die
                    server.error("Out of space, trying gc()")
                    gc();
                    addr = _fat.getFreePage();
                }
                _fat.addPage(file.id, addr)
                file.pageCount++;
                file.span++;
            }

            // Write to the page without the size
            local info = _writePage(addr, data, file.id, file.span, file.fname);

            // If we are in the middle of a page then add the changes
            _fat.addSizeToLastSpan(fileId, info.writtenFromData);

            // Shuffle the pointers forward
            addr += info.writtenToPage;
            data.seek(info.writtenFromData, 'c')

            // Keep the counters up to date
            writtenFromData += info.writtenFromData;
            writtenToPage += info.writtenToPage;

            // Go back and write the size of the previous page
            if (addr % SFFS_PAGE_SIZE == 0) {
                // if we are at the end of the page we can just write 0
                _writeSize(addr - SFFS_PAGE_SIZE, 0);
            }

        }

        // Update the FAT
        _fat.set(fileId, file);

        return { writtenFromData = writtenFromData, writtenToPage = writtenToPage, addr = addr };
    }


    //--------------------------------------------------------------------------
    function _read(fileId, start, len = null) {

        local file = _fat.get(fileId);
        local result = blob();

        // Fix the default length to everything
        if (len == null) len = file.sizeTotal - start;

        // find the initial address
        local next = start, togo = len, pos = 0, page = null;
        file.pages.seek(0);
        file.sizes.seek(0);
        while (!file.pages.eos()) {

            page = file.pages.readn('w') * SFFS_PAGE_SIZE;
            local size = file.sizes.readn('w');

            if (next < pos + size) {

                // Read the data
                local data = _readPage(page, true, next - pos, togo);
                data.data.seek(0);
                result.writeblob(data.data);

                // This is the span we have been looking for
                // server.log(format("Found start %d on page %d betweem %d and %d. Read %d of %d bytes", next, page, pos, pos + size, data.data.len(), len))

                // Have we got everything?
                togo -= data.data.len();
                if (togo == 0) break;
            }

            // Move forward
            pos += size;

        }

        return result;

    }


    //--------------------------------------------------------------------------
    function _scan() {

        local mem = imp.getmemoryfree();
        local files = {};
        local pages = blob(_pages);

        _enable();

        // Scan the headers of each page, working out what is in each
        for (local p = 0; p < _pages; p++) {

            local page = _start + (p * SFFS_PAGE_SIZE);
            local header = _readPage(page, false);
            // server.log(page + " = " + header.status.tostring())

            // Record this page's status
            pages.writen(header.status, 'b');

            if (header.status == SFFS_STATUS_USED) {

                // Make a new file entry, if required
                if (!(header.id in files)) {
                    files[header.id] <- { fn = null, pg = {}, sz = {} }
                }

                // Add the span to the files
                local file = files[header.id];
                if (header.fname != null) file.fn = header.fname;
                file.pg[header.span] <- page;
                file.sz[header.span] <- header.size;

            }

            if (files.len() > 0) {
                // server.log(format("Interim: %d files, %d ram free, %d ram used", files.len(), imp.getmemoryfree(), (mem - imp.getmemoryfree())))
            }
        }

        _disable();

        server.log("Memory used in scan: " + (mem - imp.getmemoryfree()))

        return { files = files, pages = pages };
    }


    //--------------------------------------------------------------------------
    function _writeSize(addr, size) {

        // server.log(format("    Updating size to %d at addr %d", size, addr))

        assert(addr < _end);
        assert(addr % SFFS_PAGE_SIZE == 0);

        local headerBlob = blob(SFFS_HEADER_SIZE)
        headerBlob.writen(0xFFFF, 'w'); // the id
        headerBlob.writen(0xFFFF, 'w'); // The span
        headerBlob.writen(size, 'w');

        // Write it
        _enable();
        local res = _flash.write(addr, headerBlob); // Verification will fail
        _disable();
        assert(res == 0);

    }

    //--------------------------------------------------------------------------
    function _writePage(addr, data, id, span, fname, size = 0xFFFF) {

        // server.log(format("    Writing span %d for fileId %d at addr %d", span, id, addr))

        assert(addr < _end);

        local remInPage = SFFS_PAGE_SIZE - (addr % SFFS_PAGE_SIZE);
        local remInData = (data == null) ? 0 : data.len() - data.tell();
        local writtenFromData = 0;
        local writtenToPage = 0;

        // Mark the page as used
        _fat.markPage(addr, SFFS_STATUS_USED);

        if (remInPage == SFFS_PAGE_SIZE) {

            // We are the start of a page, so create the header
            local headerBlob = blob(SFFS_HEADER_SIZE)
            headerBlob.writen(id, 'w');
            headerBlob.writen(span, 'w');
            headerBlob.writen(size, 'w');
            if (span == 0) {
                headerBlob.writen(fname.len(), 'b');
                if (fname.len() > SFFS_MAX_FNAME_SIZE) {
                    fname = fname.slice(0, SFFS_MAX_FNAME_SIZE);
                }
                if (fname.len() > 0) {
                    headerBlob.writestring(fname);
                }
            }

            // Write it
            _enable();
            local res = _flash.write(addr, headerBlob, SFFS_SPIFLASH_VERIFY);
            _disable();
            assert(res == 0);

            // Record how much we have written
            local dataToWrite = headerBlob.len();

            addr += dataToWrite;
            remInPage -= dataToWrite;
            writtenToPage += dataToWrite;

        }

        if (remInData > 0) {
            // Work out how much to write - the lesser of the remaining in the page and the remaining in the data
            local dataToWrite = (remInData < remInPage) ? remInData : remInPage;

            // Write it
            _enable();
            local res = _flash.write(addr, data, SFFS_SPIFLASH_VERIFY, data.tell(), data.tell() + dataToWrite);
            _disable();
            assert(res == 0);

            addr += dataToWrite;
            remInPage -= dataToWrite;
            remInData -= dataToWrite;
            writtenFromData += dataToWrite;
            writtenToPage += dataToWrite;

        }

        return {
                remInPage = remInPage,
                remInData = remInData,
                writtenFromData = writtenFromData,
                writtenToPage = writtenToPage
        };
    }


    //--------------------------------------------------------------------------
    function _readPage(addr, readData = false, from = 0, len = null) {

        assert(addr < _end);

        _enable();

        // Read the header
        local headerBlob = _flash.read(addr, SFFS_HEADER_SIZE + 1 + SFFS_MAX_FNAME_SIZE);

        // Parse the header
        local headerData = {};
        headerData.id <- headerBlob.readn('w');
        headerData.span <- headerBlob.readn('w');
        headerData.size <- headerBlob.readn('w');
        headerData.fname <- null;
        if (headerData.span == 0) {
            local fnameLen = headerBlob.readn('b');
            if (fnameLen > 0 && fnameLen <= SFFS_MAX_FNAME_SIZE) {
                headerData.fname = headerBlob.readstring(fnameLen);
            }
        }

        // Correct the size
        local maxSize = SFFS_PAGE_SIZE - headerBlob.tell();
        if ((headerData.span != 0xFFFF) && (headerData.size == 0 || headerData.size > maxSize)) {
            headerData.size = maxSize;
        }
        headerData.eof <- headerBlob.tell() + headerData.size;

        // Read the data if required
        if (readData) {
            local dataOffset = headerBlob.tell();
            if (len > headerData.size) len = headerData.size;
            headerData.data <- _flash.read(addr + dataOffset + from, len);
        }

        _disable();

        // Check the results
        headerData.status <- SFFS_STATUS_BAD;
        if (headerData.id == 0xFFFF && headerData.span == 0xFFFF && headerData.size == 0xFFFF && headerData.fname == null) {

            // This is a unwritten page
            headerData.status = SFFS_STATUS_FREE;

        } else if (headerData.id == 0 && headerData.span == 0 && headerData.size == 0 && headerData.fname == null) {

            // This is a erased page
            headerData.status = SFFS_STATUS_ERASED;

        } else if (headerData.id > 0 && headerData.id < 0xFFFF && headerData.span == 0 && headerData.size < 0xFFFF && headerData.fname != null) {

            // This is a header page (span = 0)
            headerData.status = SFFS_STATUS_USED;

        } else if (headerData.id > 0 && headerData.id < 0xFFFF && headerData.span > 0 && headerData.span < 0xFFFF && headerData.fname == null) {

            // This is a normal page
            headerData.status = SFFS_STATUS_USED;

        } else {

            // server.log("Reading at " + addr + " => " + Utils.logObj(headerData))
        }


        return headerData;


    }


    //--------------------------------------------------------------------------
    function _enable() {
        if (_enables++ == 0) {
            _flash.enable();
        }
    }


    //--------------------------------------------------------------------------
    function _disable() {
        if (--_enables <= 0)  {
            _enables = 0;
            _flash.disable();
        }
    }


    //--------------------------------------------------------------------------
    function _getSectorFromAddr(page) {
        return page - (page % SFFS_SECTOR_SIZE);
    }

}

class SPIFlashFileSystem.FAT {

    _filesystem = null;

    _names = null;
    _pages = null;
    _sizes = null;
    _spans = null;

    _map = null;

    _nextId = 1;

    //--------------------------------------------------------------------------
    constructor(filesystem, files = null, map = null) {

        _filesystem = filesystem;

        if (typeof files == "integer" && map == null) {
            //  Make a new, empty page map
            _map = blob(files);
            for (local i = 0; i < _map.len(); i++) {
                _map[i] = SFFS_STATUS_FREE;
            }
            files = null;
        } else {
            // Store the page map supplied
            _map = map;
        }

        // Mapping of fileId to pages, sizes and spanIds
        _pages = {};
        _sizes = {};
        _spans = {};

        // Mapping of filename to fileId
        _names = {};

        // Pull the file details out and make a more efficient FAT
        if (files != null) {
            foreach (fileId,file in files) {

                // Save the filename
                _names[file.fn] <- fileId;

                // Work out the highest spanId
                _spans[fileId] <- -1;
                foreach (span,page in file.pg) {
                    if (span > _spans[fileId]) {
                        _spans[fileId] = span;
                    }
                }

                // Save the pages as a single blob
                _pages[fileId] <- blob(file.pg.len() * 2);
                local pages = pagesOrderedBySpan(file.pg);
                foreach (page in pages) {
                    _pages[fileId].writen(page / SFFS_PAGE_SIZE, 'w');
                }
                pages = null;

                // Save the sizes
                _sizes[fileId] <- blob(file.pg.len() * 2);
                local sizes = pagesOrderedBySpan(file.sz);
                foreach (size in sizes) {
                    _sizes[fileId].writen(size, 'w');
                }
                sizes = null;

                // Save the file id
                if (fileId >= _nextId) {
                    _nextId = fileId + 1;
                }
            }
        }

    }

    //--------------------------------------------------------------------------
    function describe() {
        server.log(format("FAT contained %d files", _names.len()))
        foreach (fname,id in _names) {
            server.log(format("  File: %s, spans: %d, bytes: %d", fname, getPageCount(id), get(id).sizeTotal))
        }
    }

    //--------------------------------------------------------------------------
    function get(fileRef) {

        // Convert the file to an id
        local fileId = null, fname = null;
        if (typeof fileRef == "string") {
            fname = fileRef;
            if (fname in _names) {
                fileId = _names[fname];
            }
        } else {
            fileId = fileRef;
            foreach (filename,id in _names) {
                if (fileId == id) {
                    fname = filename;
                    break;
                }
            }
        }

        // Check the file is valid
        if (fileId == null || fname == null) throw "Invalid file reference: " + fileRef;

        // Add up the sizes
        local sizeTotal = 0, size = 0;
        _sizes[fileId].seek(0);
        while (!_sizes[fileId].eos()) {
            sizeTotal += _sizes[fileId].readn('w');
        }

        // Return the file entry
        return {
                    id = fileId,
                    fname = fname,
                    span = _spans[fileId],
                    pages = _pages[fileId],
                    pageCount = _pages[fileId].len() / 2,
                    sizes = _sizes[fileId],
                    sizeTotal = sizeTotal
                };

    }

    //--------------------------------------------------------------------------
    function set(fileId, file) {
        _spans[fileId] = file.span;
    }


    //--------------------------------------------------------------------------
    function getFileId(filename) {

        // Check the file is valid
        if (!fileExists(filename)) {
            // Create a new file
            _names[filename] <- _nextId;
            _pages[_nextId] <- blob();
            _sizes[_nextId] <- blob();
            _spans[_nextId] <- -1;
            _nextId = (_nextId + 1) % 65535 + 1; // 1 ... 64k-1
        }

        return (filename in _names) ? _names[filename] : null;
    }

    //--------------------------------------------------------------------------
    function fileExists(fileRef) {
        // Check the file is valid
        return ((fileRef in _pages) || (fileRef in _names));
    }

    //--------------------------------------------------------------------------
    function getFreePage() {

        // Find a random next free page
        local map = _map.tostring();
        local randStart = math.rand() % _map.len();
        local next = map.find(SFFS_STATUS_FREE.tochar(), randStart);
        if (next == null) {
            // Didn't find one the first time, try from the beginning
            next = map.find(SFFS_STATUS_FREE.tochar());
        }

        if (next == null) throw "No free space available";

        // server.log("Searching for: " + SFFS_STATUS_FREE.tostring() + ", in: " + Utils.logBin(_map))
        return _filesystem.dimensions().start + (next * SFFS_PAGE_SIZE);

    }

    //--------------------------------------------------------------------------
    function markPage(addr, status) {
        // Ammend the page map
        local i = (addr - _filesystem.dimensions().start) / SFFS_PAGE_SIZE;
        _map[i] = status;
    }

    //--------------------------------------------------------------------------
    function getStats() {
        local stats = { free = 0, used = 0, erased = 0, bad = 0 };
        local map = _map.tostring();
        foreach (ch in map) {
            switch (ch) {
                case SFFS_STATUS_FREE:   stats.free++; break;
                case SFFS_STATUS_USED:   stats.used++; break;
                case SFFS_STATUS_ERASED: stats.erased++; break;
                case SFFS_STATUS_BAD:    stats.bad++; break;
            }
        }
        return stats;
    }

    //--------------------------------------------------------------------------
    function addPage(fileId, page) {

        // Append the page
        get(fileId).pages.writen(page / SFFS_PAGE_SIZE, 'w')
        get(fileId).sizes.writen(0, 'w');

    }

    //--------------------------------------------------------------------------
    function addSizeToLastSpan(fileId, bytes) {

        // Read the last span's size, add the value and rewrite it
        local sizes = get(fileId).sizes;
        sizes.seek(-2, 'e');
        local size = sizes.readn('w') + bytes
        sizes.seek(-2, 'e');
        sizes.writen(size, 'w');

        // server.log(format("    Adding %d bytes to last span = %d", bytes, size))

    }

    //--------------------------------------------------------------------------
    function getPageCount(fileRef) {
        return get(fileRef).pages.len() / 2;
    }

    //--------------------------------------------------------------------------
    function forEachPage(fileRef, callback) {

        // Find the pages
        local pages = get(fileRef).pages;

        // Loop through the pages, calling the callback for each one
        pages.seek(0);
        while (!pages.eos()) {
            local page = pages.readn('w') * SFFS_PAGE_SIZE;
            callback(page);
        }

    }

    //--------------------------------------------------------------------------
    function removeFile(fname) {

        // Check the file is valid
        if (!fileExists(fname)) throw "Invalid file reference";

        // Convert the file to an id
        local id = _names[fname];

        // Remove them both
        delete _names[fname];
        delete _pages[id];
        delete _sizes[id];
        delete _spans[id];
    }


    //--------------------------------------------------------------------------
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

    //--------------------------------------------------------------------------
    constructor(filesystem, fileId, fileIdx, fname, mode) {
        _filesystem = filesystem;
        _fileIdx = fileIdx;
        _fileId = fileId;
        _fname = fname;
        _mode = mode;
    }

    //--------------------------------------------------------------------------
    function close() {
        return _filesystem._close(_fileId, _fileIdx, _dirty);
    }

    //--------------------------------------------------------------------------
    function seek(pos) {
        // Set the new pointer position
        _pos = pos;
        return this;
    }

    //--------------------------------------------------------------------------
    function tell() {
        return _pos;
    }

    //--------------------------------------------------------------------------
    function eof() {
        return _pos == _filesystem._fat.get(_fileId).sizeTotal;
    }

    //--------------------------------------------------------------------------
    function size() {
        return _filesystem._fat.get(_fileId).sizeTotal;
    }

    //--------------------------------------------------------------------------
    function read(len = null) {
        local data = _filesystem._read(_fileId, _pos, len);
        _pos += data.len();
        return data;
    }

    //--------------------------------------------------------------------------
    function write(data) {
        if (_mode == "r") throw "Can't write - file mode is 'r'";
        local info = _filesystem._write(_fileId, _waddr, data);
        _wpos += info.writtenFromData;
        _waddr = info.addr;
        _dirty = true;
        return info.writtenToPage;
    }

}
