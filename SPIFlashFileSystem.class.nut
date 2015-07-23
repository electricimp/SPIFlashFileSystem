/*
 *   To do
 *   - Functionality
 *     - Automatically call gc() when appropriate
 *     - repair() should also repair index references to data pages
 *   - Style
 *     - Make the code Library-friendly
 *   - Optimisation
 *     - Scanning for reads and writes has been optimised with a cache. There is always room for more.
 *     - Garbage collection is erasing sectors multiple times, especially the lookup sectors.
 *     - The fat is expensive in memory. 150 files = 65kb. 
 *     - Put four lookup tables on every fourth block instead of one lookup table per block.
 *   - Checks
 *     - Its probably going to be messy if we open a file (for writing) twice at a time.
 *     - Handle wraparound of the _lastId
 *
 */


/*

Inspired by Spiffs (https://github.com/pellepl/spiffs/blob/master/docs/TECH_SPEC)

Physical Sector size = 4kb (smallest erasable part)
Logical block size = 64kb (each block contains a lookup table in the first sector)
Logical page size = 256b (each page contains a small header and data)

Each object (file) has an object id which ties together the separated parts of the file
Objects have one+ index pages and one+ data pages
The index page holds where the data pages are and the first index page also holds the filename and size
Each logical page has 5 bytes of header (meta data) including:
- type: index or data
- status: used, deleted, finalized, etc
- object id 
- span index

The first two pages of each block contains a lookup table - an array of object ids, one per logical page. 
Each id has one bit dedicated to the type (index or data).
This way you can quickly find free data pages and index pages.
We ended up wasting the whole first sector of each block because garbage collection was hard without it.

object id = 1 ... 64k/2-1 = 32,766. 0x0000 means deleted, 0xffff means free, mask 0x8000 means index.

*/


//==============================================================================
class SPIFlashFileSystem {
    
    _flash = null;
    _size = null;
    _start = null;
    _end = null;
    _len = null;
    
    _blocks = 0;
    _sectors = 0;
    _pages = 0;
    
    _enables = 0;
    _lastFilePtr = 0;
    _lastId = 0;

    _fat = null;
    _openFiles = null;
    
    _pageCache = null;
    _freePageCache = null;

    static version = [0, 1, 0];

    //--------------------------------------------------------------------------
    constructor(start = null, end = null, flash = null) {
        
        const SFFS_BLOCK_SIZE = 65536;
        const SFFS_SECTOR_SIZE = 4096;
        const SFFS_PAGE_SIZE = 256;
        const SFFS_PAGES_PER_SECTOR = 16;
        const SFFS_PAGES_PER_BLOCK = 256;
        const SFFS_SECTORS_PER_BLOCK = 16;
        
        const SFFS_HEADER_SIZE = 5;
        const SFFS_BODY_SIZE = 251; // SFFS_PAGE_SIZE - SFFS_HEADER_SIZE
    
        const SFFS_FLAGS_NEW = 0x01;
        const SFFS_FLAGS_USED = 0x02;
        const SFFS_FLAGS_DATA = 0x04;
        const SFFS_FLAGS_INDEX = 0x08;
        const SFFS_FLAGS_DELETED = 0x10;
        const SFFS_FLAGS_DIRTY = 0x20;
        const SFFS_FLAGS_APPENDED = 0x40;
        const SFFS_FLAGS_FREE = 0xFF;
        
        const SFFS_LOOKUP_MASK_ID = 0x7FFF;
        const SFFS_LOOKUP_MASK_INDEX = 0x8000;
        const SFFS_LOOKUP_FREE  = 0xFFFF;
        const SFFS_LOOKUP_ERASED  = 0x0000;

        const SFFS_LOOKUP_STAT_ERASED = 0x00;
        const SFFS_LOOKUP_STAT_INDEX  = 0x01;
        const SFFS_LOOKUP_STAT_DATA   = 0x02;
        const SFFS_LOOKUP_STAT_FREE   = 0xFF;
        
        const SFFS_FREECACHE_MINIMUM = 20;
        
        const SFFS_SPIFLASH_VERIFY = 1; // SPIFLASH_DONTVERIFY = 0, SPIFLASH_POSTVERIFY = 1, SPIFLASH_PREVERIFY = 2

        _flash = flash ? flash : hardware.spiflash;

        _enable();
        _size = _flash.size();
        _disable();
        
        if (start == null) _start = 0;
        else if (start < _size) _start = start;
        else throw "Invalid start value";
        if (_start % SFFS_BLOCK_SIZE != 0) throw "start must be at a block boundary";
        
        if (end == null) _end = _size;
        else if (end > _start) _end = end;
        else throw "Invalid end value";
        if (_end % SFFS_BLOCK_SIZE != 0) throw "end must be at a block boundary";
        
        _fat = {};
        _openFiles = {};
        _pageCache = {};
        _freePageCache = [];
        
        _len = _end - _start;
        _blocks = _len / SFFS_BLOCK_SIZE;
        _sectors = _len / SFFS_SECTOR_SIZE;
        _pages = _len / SFFS_PAGE_SIZE;

    }
    
    
    //--------------------------------------------------------------------------
    function init(callback = null) {
        
        if (_openFiles.len() > 0) return server.error("Can't call init() with open files");
        
        // Scan the object lookup tables for files
        _fat = {};
        _openFiles = {};
        _pageCache = {};
        _freePageCache = [];
        
        _scan(function(file) {
            // server.log(Utils.logObj(file));
            assert(file != null && file.fname != null);
            _fat[file.fname] <- file;
            if (file.id > _lastId) _lastId = file.id; 
            if (callback) callback(file);
        }.bindenv(this))

    }
    
    
    //--------------------------------------------------------------------------
    function dimensions() {
        return { "size": _size, "len": _len, "start": _start, "end": _end }
    }
    
    
    //--------------------------------------------------------------------------
    function eraseFile(fname) {
        if (!(fname in _fat)) throw "Can't find file '" + fname + "' to erase";
        
        // server.log("Erasing " + fname)
        local file = _fat[fname];
        local zeros = blob(SFFS_HEADER_SIZE);
        
        _enable();
        
        // Scan for the pages for this file
        local scan = _getFilePages(file);

        // Zero out the data pages
        foreach (page,span in scan.psDat) {
            // server.log("+ Data @ " + page);
            local res = _flash.write(page, zeros, SFFS_SPIFLASH_VERIFY);
            assert(res == 0);
        }
        
        // Zero out the index pages
        foreach (page,span in scan.psIdx) {
            // server.log("+ Index @ " + page);
            local res = _flash.write(page, zeros, SFFS_SPIFLASH_VERIFY);
            assert(res == 0);
        }

        // Zero out the lookup pages in any block that matches the file id
        for (local b = 0; b < _blocks; b++) {
            
            // Read the first two pages
            local block = _start + (b * SFFS_BLOCK_SIZE);
            local lookupData = _flash.read(block, 2*SFFS_PAGE_SIZE);

            local lookupDataChanged = false;
            lookupData.seek(2 * SFFS_PAGES_PER_SECTOR); // Skip past the first sector
            while (!lookupData.eos()) {
                
                // Read the next page
                local objData = lookupData.readn('w');
                local id = (objData & SFFS_LOOKUP_MASK_ID);
                if (id == file.id) {
                    
                    // We have a matching id, so go back over it with 0's
                    lookupData.seek(-2, 'c');
                    lookupData.writen(0x0000, 'w');
                    lookupDataChanged = true;
                }
                
            }

            // Now write the lookup table back
            if (lookupDataChanged) {
                lookupData.seek(0);
                local res = _flash.write(block, lookupData, SFFS_SPIFLASH_VERIFY);
                assert(res == 0);
            }
        }
        
        _disable();
        
        // Update the fat
        delete _fat[fname];
    }
    
    
    //--------------------------------------------------------------------------
    function eraseAll() {
        // Format all the sectors
        _enable()
        for (local i = 0; i < _sectors; i++) {
            _flash.erasesector(i * SFFS_SECTOR_SIZE);
        }
        _disable()
        imp.sleep(0.05);

        // Close all open files and empty the FAT
        _fat = {};
        _openFiles = {};
        _pageCache = {};
        _freePageCache = [];
        
        _lastFilePtr = 0;
        _lastId = 0;

        server.log("Filesystem erased");
    }
    
    
    //--------------------------------------------------------------------------
    function fileExists(fname) {
        return (fname in _fat);
    }
    
    
    //--------------------------------------------------------------------------
    function info(fname) {
        
        if (typeof fname == "integer") {
            // We have a file pointer
            local fileptr = fname;
            return _openFiles[fileptr];
        } else if (typeof fileptr == "string") {
            // We have a file name
            if (!(fname in _fat)) {
                throw "Can't find '" + fname + "' info.";
            }
            return _fat[fname];
        }
    }
    
    
    //--------------------------------------------------------------------------
    function size(fileptr) {
        return info(fileptr).size;
    }
    
    
    //--------------------------------------------------------------------------
    function open(fname, mode) {
        // Check the mode
        if ((mode == "r") && !(fname in _fat)) {
            throw "Can't open '" + fname + "' for reading, not found.";
        } else if ((mode == "w") && (fname in _fat)) {
            throw "Can't open '" + fname + "' for writing, already exists.";
        } else if (mode != "r" && mode != "w" && mode != "a") {
            throw "Unknown mode: " + mode;
        } else
        
        // Create a new file pointer from the FAT or a new file
        _lastFilePtr++;
        if (fname in _fat) {
            // This is an existing file, so just point to the same FAT entry
            _openFiles[_lastFilePtr] <- _fat[fname];
        } else {
            // Create a new open file entry for this file but not a FAT entry
            _lastId = (_lastId + 1) % SFFS_LOOKUP_MASK_ID;
            // NOTE: We really should check if _lastId already exists in the file system
            _openFiles[_lastFilePtr] <- { 
                id = ++_lastId, 
                fname = fname, 
                flags = SFFS_FLAGS_NEW, 
                size = 0, 
                lsDat = 0, 
                lsIdx = 0,
                pgNxt = null,
                pgsIdx = blob(),
                pgsDat = blob()
            };
        }
        
        // Return a new file object
        return SPIFlashFileSystem.File(this, _lastFilePtr, fname, mode);
    }
    
    
    //--------------------------------------------------------------------------
    function _close(fileptr) {

        // If the file has changed, write the final results to the filesystem
        local file = _openFiles[fileptr];
        local scan = null;
        local psIdx = null;
        local psDat = null;

        if (file.flags & (SFFS_FLAGS_DIRTY | SFFS_FLAGS_APPENDED)) {
            // Scan for all the pages used by this file
            scan = _getFilePages(file);
            psIdx = _sortTableByValues(scan.psIdx);
            psDat = _sortTableByValues(scan.psDat);
        }
        
        // If we have an appended file then we have to remove the old index header to update the size
        if (file.flags & SFFS_FLAGS_APPENDED && psIdx.len() > 0) {
            
            _erasePage(psIdx[0]);

            psIdx[0] = _nextFreePage();

            // Update the cache too
            if (file.id in _pageCache) {
                _pageCache[file.id].psIdx[0] <- psIdx[0];
            }
            
        }

        // Check if the file has been changed
        if (file.flags & SFFS_FLAGS_DIRTY) {

            // Remove the dirty flag and add the used flag
            file.flags = file.flags ^ SFFS_FLAGS_DIRTY;
            file.flags = file.flags | SFFS_FLAGS_USED;

            // server.log(format("Closing '%s' which is now %d bytes\n\n", _openFiles[fileptr].fname, _openFiles[fileptr].size));
            
            // Write all the indices
            local span = 0;
            while (psDat.len() > 0) {
                
                // Use an existing index or make a new one
                local index = null;
                if (psIdx.len() > 0) {
                    
                    // Use an existing index
                    index = psIdx[0];
                    psIdx.remove(0);
                    
                } else {

                    // Make a new index
                    index = _nextFreePage();

                    // Add it to the cache if required
                    if (file.id in _pageCache) {
                        _pageCache[file.id].psIdx[span] <- index;
                    }
                }
                
                // Now write the index, possible over the previous one.
                _writeIndexPage(file, index, psDat, span++);
            }
            
        }
        
        // Now drop the file pointer;
        delete _openFiles[fileptr];
        
    }
    
    
    //--------------------------------------------------------------------------
    function _read(fileptr, ptr, len = null) {

        // Check the length is valid
        local file = _openFiles[fileptr];
        if (len == null) len = file.size;
        local size = file.size;
        if (ptr + len >= size) len = size - ptr;
        if (len <= 0) return blob();
        
        // Now read the data
        local data = blob();
        local rem_total = len;
        local page_no = ptr / SFFS_BODY_SIZE;
        local page_offset = ptr % SFFS_BODY_SIZE;
        local togo = ptr;

        // server.log("Reading: " + ptr + " (page " + page_no + ", offset " + page_offset + ") from " + file.psDat.len() + " psDat and " + file.psIdx.len() + " psIdx");
        // Scan for the pages for this file
        local scan = _getFilePages(file);
        local psDat = _sortTableByValues(scan.psDat);
        
        _enable();
        foreach (page in psDat) {
            // Shuffle to the right page
            if (togo <= SFFS_BODY_SIZE) {

                // Read till the end of the page at most
                local rem_in_page = SFFS_BODY_SIZE - page_offset;
                local rem = (rem_total > rem_in_page) ? rem_in_page : rem_total;
                _flash.readintoblob(page + SFFS_HEADER_SIZE + page_offset, data, rem);
                // server.log("Reading from: " + (page + SFFS_HEADER_SIZE + page_offset) + " in span " + file.psDat[page]);
    
                // Reload for next page
                page_offset = 0;
                rem_total -= rem;
                if (rem_total == 0) break;
            }
            togo -= SFFS_BODY_SIZE;
        }
        _disable();
        
        data.seek(0);
        return data;
    }


    //--------------------------------------------------------------------------
    function _write(fileptr, data) {

        // Make sure we have a blob
        if (typeof data == "string") {
            local data_t = blob(data.len());
            data_t.writestring(data);
            data = data_t;
            data.seek(0);
        } else if (typeof data != "blob") {
            throw "Can only write blobs and strings";
        }
        // server.log(format("Writing to '%s' for %d bytes", _openFiles[fileptr].fname, data.len()));

        local bytesWritten = 0;
        local file = _openFiles[fileptr];
        
        // Make sure the open file and the FAT match. This is only relevant when its a new file
        _fat[file.fname] <- file;
        
        _enable();
        
        // Make sure we have an index
        if (file.lsIdx == 0) {

            // Make sure we never come back here again
            file.lsIdx++;
            
            // Create a new index header page
            local index = _nextFreePage();

            // Add it to the cache if required
            if (file.id in _pageCache) {
                _pageCache[file.id].psIdx[0] <- index;
            }
            
            _writeIndexPage(file, index);

        }
        
        // Now write all the data
        local pagesRequired = math.ceil(1.0 * data.len() / SFFS_BODY_SIZE).tointeger();
        local freePages =  _nextFreePage(pagesRequired);
        while (!data.eos()) {

            // Find the next write location
            if (file.size % SFFS_BODY_SIZE == 0) {
                
                file.lsDat++;
                
                // Just in case we have run out, get another page
                if (freePages.len() == 0) freePages =  _nextFreePage(1);
                file.pgNxt = freePages[0];
                freePages.remove(0);
                // server.log("New page, span " + file.lsDat + " at " + file.pgNxt);
                
                // Add it to the cache if required
                if (file.id in _pageCache) {
                    _pageCache[file.id].psDat[file.lsDat] <- file.pgNxt;
                }
                
            } else {
                // server.log("Same page, span " + file.lsDat + " at " + file.pgNxt);
            }

            // Write the data to the free page
            local bytes = _writeDataPage(file, data, file.pgNxt, file.lsDat);
            bytesWritten += bytes;
            file.size += bytes;
            // server.log("+- " + bytes + " bytes")
            
            // Add the dirty flag and appended flag
            file.flags = file.flags | SFFS_FLAGS_DIRTY;
            if (file.flags & SFFS_FLAGS_USED) {
                file.flags = file.flags | SFFS_FLAGS_APPENDED;
            }
        
        }
        
        _disable();
        
        return bytesWritten;
    }
    

    //--------------------------------------------------------------------------
    function _writeIndexPage(file, indexPage, dataPages = null, span = 0) {
        _enable();
        
        local block = _getBlockFromAddr(indexPage);
        // server.log(format("- Writing index span %d for id %d at %d in block %d", span, file.id, indexPage, block))

        // Write the new index
        local indexData = blob(SFFS_HEADER_SIZE);
        indexData.writen(SFFS_FLAGS_INDEX, 'b');
        indexData.writen(file.id, 'w');
        indexData.writen(span, 'w');
        // server.log("Index span " + span);
        
        if (span == 0) {
            // This is an index header page, so contains some extra info
            if (file.flags & SFFS_FLAGS_NEW) {
                // We dont know the final size yet
                indexData.writen(0xFFFFFFFF, 'i');
                file.flags = file.flags ^ SFFS_FLAGS_NEW;
            } else {
                indexData.writen(file.size, 'i');
            }
            indexData.writen(file.fname.len(), 'b');
            indexData.writestring(file.fname);
        }
        
        // Append the list of pages, until the end of the page
        if (dataPages != null) {
            while (dataPages.len() > 0 && indexData.len() < 255) {
                // Add the page number of this page to the index
                local dataPage = dataPages[0];
                local dataPageNumber = dataPage / SFFS_PAGE_SIZE;
                indexData.writen(dataPageNumber, 'w');
                // server.log(format("* Wrote dataPage %02x on index %02x for id %d", dataPage, indexPage, file.id))

                // Shift the first page off
                dataPages.remove(0);
            }
        }
        local res = _flash.write(indexPage, indexData, SFFS_SPIFLASH_VERIFY);
        assert(res == 0);

        // server.log("Writing index span " + span + ", for filename " + file.fname + " at " + indexPage);
        
        // Update the object lookup table to indicate this is an index of this particular file id
        local lookup = block + (2 * (indexPage - block) / SFFS_PAGE_SIZE);
        local lookupData = blob(2);
        lookupData.writen(file.id | SFFS_LOOKUP_MASK_INDEX, 'w');
        local res = _flash.write(lookup, lookupData, SFFS_SPIFLASH_VERIFY);
        assert(res == 0);

        // Update the FAT
        if ("pgsIdx" in file) {
            _addPageToCache(indexPage, file.pgsIdx);
        } else {
            // We don't know which file this belongs to. This should only happen inside gc() so it should be safe to ignore.
        }

        // Track the last index span 
        if ("lsIdx" in file && span > file.lsIdx) file.lsIdx = span;

        _disable();
    }
    
    
    //--------------------------------------------------------------------------
    function _writeDataPage(file, data, page, span) {
        _enable();
        
        local pageOffset = file.size % SFFS_BODY_SIZE;
        local block = _getBlockFromAddr(page);
        
        // server.log(format("- Writing data span %d for id %d at %d in block %d", span, file.id, page, block))
        
        // Write the page header
        local header = blob(SFFS_HEADER_SIZE);
        header.writen(SFFS_FLAGS_DATA, 'b');
        header.writen(file.id, 'w');
        header.writen(span, 'w');
        local res = _flash.write(page, header, SFFS_SPIFLASH_VERIFY);
        assert(res == 0);
        // server.log(format("+ Writing data header at %d for %d bytes (span %d)", page, header.len(), span))
        
        // Write the page data
        local ptr = page + SFFS_HEADER_SIZE + pageOffset;
        local rem_in_page = SFFS_BODY_SIZE - pageOffset;
        local rem_in_data = data.len() - data.tell();
        local bytes = (rem_in_page < rem_in_data) ? rem_in_page : rem_in_data;
        local res = _flash.write(ptr, data.readblob(bytes), SFFS_SPIFLASH_VERIFY);
        assert(res == 0);
        // server.log(format("+ Writing data at %d for %d bytes", ptr, bytes))

        // Update the object lookup table
        local lookup = block + (2 * (page - block) / SFFS_PAGE_SIZE);
        local data = blob(1);
        data.writen(file.id, 'w');
        local res = _flash.write(lookup, data, SFFS_SPIFLASH_VERIFY);
        assert(res == 0);
        // server.log(format("= Writing data lookup at %d to 0x%04x\n\n", lookup, file.id))

        // Update the FAT
        if ("pgsDat" in file) {
            _addPageToCache(page, file.pgsDat);
        } else {
            // We don't know which file this belongs to. This should only happen inside gc() so it should be safe to ignore.
        }

        _disable();
        
        // Let the caller know how many bytes where transfered out of the data 
        return bytes;

    }


    //--------------------------------------------------------------------------
    function _addPageToCache(page, cache) {
        local page = page / SFFS_PAGE_SIZE;
        local found = false;
        cache.seek(0);
        while (!cache.eos()) {
            if (page == cache.readn('w')) {
                found = true;
                break;
            }
        }
        if (!found) {
            cache.seek(0, 'e');
            cache.writen(page, 'w');
        }
    }
    

    //--------------------------------------------------------------------------
    function _erasePage(page) {
        
        local block = _getBlockFromAddr(page);
        local zeros = blob(SFFS_HEADER_SIZE);
        
        // server.log(format("- Erasing page %d in block %d", page, block))

        _enable();
        
        // Zero out the index page
        local res = _flash.write(page, zeros, SFFS_SPIFLASH_VERIFY);
        assert(res == 0);

        // Update the object lookup table to indicate this page is erased
        local lookup = block + (2 * (page - block) / SFFS_PAGE_SIZE);
        local lookupData = blob(2);
        lookupData.writen(0x0000, 'w');
        local res = _flash.write(lookup, lookupData, SFFS_SPIFLASH_VERIFY);
        assert(res == 0);

        _disable();
    }


    //--------------------------------------------------------------------------
    function _copyPage(srcPage, dstPage, lookup) {
        _enable();

        // Update the existing pages for this file
        local srcPageIndex = srcPage / SFFS_PAGE_SIZE;
        local dstPageIndex = dstPage / SFFS_PAGE_SIZE;
        local scan = (lookup.stat == SFFS_LOOKUP_STAT_INDEX) ? null : _getFilePages(null, lookup.id);

        // Write the original data over the free space
        local srcData = _flash.read(srcPage, SFFS_PAGE_SIZE);
        local res = _flash.write(dstPage, srcData, SFFS_SPIFLASH_VERIFY);
        assert(res == 0);

        // Update the object lookup table for the destination
        local block = _getBlockFromAddr(dstPage);
        local lookupIndex = 2 * (dstPage - block) / SFFS_PAGE_SIZE;
        local lookupUpdate = blob(2);
        lookupUpdate.writen(lookup.raw, 'w');
        local res = _flash.write(block + lookupIndex, lookupUpdate, SFFS_SPIFLASH_VERIFY);
        assert(res == 0);

        // Update the FAT
        _updateFilePages(srcPage, dstPage);
        
        // If this is a data page then update the index page list
        if (lookup.stat != SFFS_LOOKUP_STAT_INDEX) {
            
            // Look through each of the indices for the page reference
            local last_span = 0;
            local psIdx = _sortTableByValues(scan.psIdx);
            local indexErased = false, indexAdded = false;
            foreach (indexPage in psIdx) {

                // Read the index page
                local indexUpdated = false;
                local index = _readIndexPage(indexPage, true);
                last_span = index.span;
                
                // Check if the source page is in this index
                local locationOfSrc = index.dataPages.find(srcPage);
                if (locationOfSrc != null) {
                    
                    index.raw.seek(index.header);
                    while (index.raw.len() - index.raw.tell() >= 2) {
                        local pageIndex = index.raw.readn('w');
                        if (indexAdded == false && pageIndex == SFFS_LOOKUP_FREE) {

                            // Write the new entry over the previous one
                            // server.log("+ Found free spot for new pageData page")
                            index.raw.seek(-2, 'c');
                            index.raw.writen(dstPageIndex, 'w');
                            indexAdded = true;
                            indexUpdated = true;

                        } else if (indexErased == false && pageIndex == srcPageIndex) {
                            
                            // Erase the old entry 
                            // server.log("+ Found and erased matching pageData page")
                            index.raw.seek(-2, 'c');
                            index.raw.writen(SFFS_LOOKUP_ERASED, 'w');
                            indexErased = true;
                            indexUpdated = true;
                            
                        }
                        
                        // Have we finished?
                        if (indexErased && indexAdded) break;
                    }

                    // Write the updated index to disk
                    if (indexUpdated) {
                        index.raw.seek(0);
                        // server.log(format("+ Writing back index at %02x", indexPage))
                        local res = _flash.write(indexPage, index.raw, SFFS_SPIFLASH_VERIFY);
                        assert(res == 0);
                    }
                    
                    // Have we finished?
                    if (indexErased && indexAdded) break;

                }

            }
            
            // If we are at the end and still haven't found space so we need a new index page
            if (!indexAdded) {
                
                // Create a new index page
                local index = _nextFreePage();
                _writeIndexPage(lookup, index, [dstPage], last_span+1);
                // server.log(format("- Writing index span %d for id %d at %02x in block %02x", last_span+1, lookup.id, index, block))

            }
            
            // server.log("\n");
        }
        
        _disable();
        
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
    function _readLookupPage(block, withRaw = false) {

        
        // Read the first two page (the lookup table)
        _enable();
        local lookupData = _flash.read(block, 2 * SFFS_PAGE_SIZE);
        _disable();

        // Skip past the first 2x16 bytes, which are the lookup pages (the whole first sector)
        local page = block + SFFS_SECTOR_SIZE;
        lookupData.seek(2 * SFFS_PAGES_PER_SECTOR); 
        
        // Store this in a table of arrays instead of an array of tables.
        // An array of tables eats up all available memory.
        local lookupPages = { count = 0, id = [], stat = [], page = [], addr = [], raw = [] };
        while (!lookupData.eos()) {
            
            // Read the next page
            local addr = block + lookupData.tell();
            local objData = lookupData.readn('w');
            
            lookupPages.count++;
            lookupPages.page.push(page);
            lookupPages.addr.push(addr);
            lookupPages.id.push(objData & SFFS_LOOKUP_MASK_ID);
            if (withRaw) lookupPages.raw.push(objData);
            
            if (objData == SFFS_LOOKUP_FREE) {
                lookupPages.stat.push(SFFS_LOOKUP_STAT_FREE);
            } else if (objData == SFFS_LOOKUP_ERASED) {
                lookupPages.stat.push(SFFS_LOOKUP_STAT_ERASED);
            } else if ((objData & SFFS_LOOKUP_MASK_INDEX) == SFFS_LOOKUP_MASK_INDEX) {
                lookupPages.stat.push(SFFS_LOOKUP_STAT_INDEX);
            } else {
                lookupPages.stat.push(SFFS_LOOKUP_STAT_DATA);
            }

            // Move forward
            page += SFFS_PAGE_SIZE;
        }
        
        return lookupPages;
        
    }
    

    //--------------------------------------------------------------------------
    function _getLookupData(lookupPages, i) {
        local lookup = {};
        lookup.id <- lookupPages.id[i];
        lookup.stat <- lookupPages.stat[i];
        lookup.page <- lookupPages.page[i];
        lookup.addr <- lookupPages.addr[i];
        if (lookupPages.raw.len() > 0) lookup.raw <- lookupPages.raw[i];
        return lookup;
    }
    
    
    //--------------------------------------------------------------------------
    function _readIndexPage(indexPage, withRaw = false) {
        
        _enable();
        
        // Read the index page and parse the header
        local indexData = _flash.read(indexPage, SFFS_PAGE_SIZE);
        // server.log("indexData at " + indexPage + " is: " + Utils.logBin(indexData.tostring().slice(0, 12)));
        
        local index = {};
        index.flags <- indexData.readn('b');
        index.id <- indexData.readn('w'); // This should match the previous id
        index.span <- indexData.readn('w');
        if (index.span == 0) {
            index.size <- indexData.readn('i');
            local fnameLen = indexData.readn('b');
            index.fname <- indexData.readstring(fnameLen);
        }
        index.header <- indexData.tell();
        if (withRaw) index.raw <- indexData;
        index.dataPages <- [];

        // Read the page numbers if there are any left
        while (indexData.len() - indexData.tell() >= 2) {
            local dataPageOffset = indexData.readn('w');
            if (dataPageOffset != SFFS_LOOKUP_ERASED && dataPageOffset != SFFS_LOOKUP_FREE) {
                index.dataPages.push(dataPageOffset * SFFS_PAGE_SIZE);
                // server.log(format("* Found dataPage %02x on index %02x for id %d", (dataPageOffset * SFFS_PAGE_SIZE), indexPage, index.id))
            }
        }

        _disable();
        
        return index;
    }


    //--------------------------------------------------------------------------
    function _readDataPage(dataPage, withData = false) {
        
        assert(dataPage < _end);

        _enable();

        local dataBlob = _flash.read(dataPage, withData ? SFFS_PAGE_SIZE : SFFS_HEADER_SIZE);
        
        // Parse the header
        local data = {};
        data.flags <- dataBlob.readn('b');
        data.id <- dataBlob.readn('w'); 
        data.span <- dataBlob.readn('w');
        
        if (withData) {
            data.data <- dataBlob.readblob(SFFS_PAGE_SIZE - 5);
        }
        
        _disable();
        return data;
    }
    
    
    //--------------------------------------------------------------------------
    function _scan(callback) {

        _enable();
        
        local files = {};
        
        // Scan the object lookup tables in each blocks, starting at a random block
        local b_start = math.rand() % _blocks;
        b_start = 0; // NOTE: Remove this
        for (local b = 0; b < _blocks; b++) {
            
            local b_next = (b + b_start) % _blocks;
            local block = _start + (b_next * SFFS_BLOCK_SIZE);
            
            // Read the lookup table
            local lookupData = _readLookupPage(block);
            
            // Scan through the pages starting at a random location
            local l_start = math.rand() % lookupData.count;
            l_start = 0; // NOTE: Remove this
            for (local i = 0; i < lookupData.count; i++) {

                local l_next = (i + l_start) % lookupData.count;
                local lookup = _getLookupData(lookupData, l_next);
                if (lookup.stat == SFFS_LOOKUP_STAT_INDEX) {
                    
                    // Read the index page
                    local index = _readIndexPage(lookup.page);
                    
                    // server.log(format("Found index id %d span %d at page %d named %s with %d data pages", index.id, index.span, lookup.page, ("fname" in index ? index.fname : "?"), index.dataPages.len()))
                    if (index.id != lookup.id) {
                        server.error("The index at page " + lookup.page + " is invalid.");
                        continue;
                    }

                    // Read the page numbers
                    local lsIdx = index.span, lsDat = 0, pgNxt = 0;
                    foreach (dataPage in index.dataPages) {

                        // Read the data header
                        local data = _readDataPage(dataPage);

                        // Track the highest data span
                        if (data.span > lsDat) {
                            lsDat = data.span;
                            pgNxt = dataPage;
                        }
                        // server.log("Found span " + header.span + " at page " + dataPage);
                    }
                    
                    // Store the new file data
                    local file = null;
                    if (!(lookup.id in files)) {
                        
                        // This is a new file, so create an entry
                        file = { 
                            id    = lookup.id, 
                            fname = null,
                            size  = 0,
                            flags = SFFS_FLAGS_USED,
                            lsIdx = 0,
                            lsDat = 0, 
                            pgNxt = pgNxt,
                            pgsIdx = blob(),
                            pgsDat = blob(),
                        };
                        files[lookup.id] <- file;
                        
                    } else {
                        
                        // We already have this file, so this is new info
                        file = files[lookup.id];
                    } 

                    // Update the filename and size from the index
                    if ("fname" in index) file.fname = index.fname;
                    if ("size" in index) file.size = index.size == -1 ? 0 : index.size;

                    // Track the page usage
                    _addPageToCache(lookup.page, file.pgsIdx);
                    
                    // Update the last span values
                    if (lsIdx > file.lsIdx) {
                        file.lsIdx = lsIdx;
                    }
                    if (lsDat > file.lsDat) {
                        file.lsDat = lsDat;
                        file.pgNxt = pgNxt;
                    }
                    
                } else if (lookup.stat == SFFS_LOOKUP_STAT_DATA) {

                    // Store the new file data
                    local file = null;
                    if (!(lookup.id in files)) {
                        
                        // This is a new file, so create an entry
                        file = { 
                            id    = lookup.id, 
                            fname = null,
                            size  = 0,
                            flags = SFFS_FLAGS_USED,
                            lsIdx = 0,
                            lsDat = 0, 
                            pgNxt = 0,
                            pgsIdx = blob(),
                            pgsDat = blob(),
                        };
                        files[lookup.id] <- file;
                        
                    } else {
                        
                        // We already have this file, so this is new info
                        file = files[lookup.id];
                    } 

                    // Track the page usage
                    _addPageToCache(lookup.page, file.pgsDat);
                    
                }
                
            }
        }

        // We have completed the scan, call the callback
        foreach (id, file in files) {
            if (callback(file) == true) {
                _disable();        
                return;
            }
        }
        
        // If we have got to the end of the storage, we just need to disable and finish
        _disable();        

    }
    
    
    //--------------------------------------------------------------------------
    function _getFileFromFileId(fileId) {
        foreach (fname,file in _fat) {
            if (file.id == fileId) return file;
        }
    }


    //--------------------------------------------------------------------------
    function _updateFilePages(srcPage, dstPage) {
        
        // Convert to the word size
        local srcPage = srcPage / SFFS_PAGE_SIZE;
        local dstPage = dstPage / SFFS_PAGE_SIZE;
        if (srcPage == dstPage) return;
        
        // For each file in the fat
        foreach (fname, file in _fat) {
            
            // Scan through all the index pages
            file.pgsIdx.seek(0);
            while (!file.pgsIdx.eos()) {
                
                // Read the index
                local indexPage = file.pgsIdx.readn('w');
                if (indexPage == srcPage) {
                    file.pgsIdx.seek(-2, 'c');
                    file.pgsIdx.writen(dstPage, 'w');
                }
            }
    
            // Scan through all the data pages
            file.pgsDat.seek(0);
            while (!file.pgsDat.eos()) {
                
                // Read the index
                local dataPage = file.pgsDat.readn('w');
                if (dataPage == srcPage) {
                    file.pgsDat.seek(-2, 'c');
                    file.pgsDat.writen(dstPage, 'w');
                }
            }
    

        }
    }

    //--------------------------------------------------------------------------
    function _getFilePages(file, fileId = null) {

        // Normalise the parameters
        if (file == null) {
            file = _getFileFromFileId(fileId);
        } else {
            fileId = file.id;
        }

        // Check if we have the fileId in the cache
        if (fileId in _pageCache) return _pageCache[fileId];

        _enable();

        local psIdx = {}, psDat = {};

        // Scan through all the index pages
        file.pgsIdx.seek(0);
        while (!file.pgsIdx.eos()) {
            
            // Read the index
            local indexPage = file.pgsIdx.readn('w') * SFFS_PAGE_SIZE;
            local index = _readIndexPage(indexPage);
            psIdx[indexPage] <- index.span;
        }

        // Scan through all the data pages
        file.pgsDat.seek(0);
        while (!file.pgsDat.eos()) {
            
            // Read the index
            local dataPage = file.pgsDat.readn('w') * SFFS_PAGE_SIZE;
            local data = _readDataPage(dataPage);
            psDat[dataPage] <- data.span;
        }

        _disable();   
        
        // Save the result in/as the cache
        if (_pageCache.len() > 4) _pageCache = {};
        _pageCache[fileId] <- { psDat=psDat, psIdx=psIdx };
        
        return _pageCache[fileId];

    }
    
    
    //--------------------------------------------------------------------------
    function _nextFreePage(noRequired = null, ignoreSector = null) {

        // Scan the object lookup tables for free pages
        _enable();

        local count = (noRequired == null) ? 1 : noRequired;
        local free = [];
        
        // Take from the cache first, unless it is ignoreing a sector
        if (ignoreSector != null) _freePageCache = [];
        while (_freePageCache.len() > 0 && free.len() < count) {
            free.push(_freePageCache[0]);
            _freePageCache.remove(0);
        }

        // Scan the object lookup tables in each blocks, starting at a random block
        if (free.len() < count) {
            
            local b_start = math.rand() % _blocks;
            b_start = 0; // NOTE: Remove this
            for (local b = 0; b < _blocks; b++) {
                
                local b_next = (b + b_start) % _blocks;
                local block = _start + (b_next * SFFS_BLOCK_SIZE);
                
                // Read the lookup table
                local lookupData = _readLookupPage(block);
                
                // Scan through the pages starting at a random location
                local l_start = math.rand() % lookupData.count;
                l_start = 0; // NOTE: Remove this
                for (local i = 0; i < lookupData.count; i++) {
    
                    local l_next = (i + l_start) % lookupData.count;
                    local lookup = _getLookupData(lookupData, l_next);
                    if (lookup.stat == SFFS_LOOKUP_STAT_FREE) {
    
                        local sector = _getSectorFromAddr(lookup.page);
                        if (sector != ignoreSector) {
                            
                            // Store this page as free either for the caller or the cache
                            if (free.len() < count) {
                                // Make sure it isn't already taken from the free page cache
                                if (free.find(lookup.page) == null) {
                                    free.push(lookup.page)
                                }
                            } else {
                                _freePageCache.push(lookup.page);
                            }
                            
                            // Do we have all we need?
                            if (free.len() == count && _freePageCache.len() >= SFFS_FREECACHE_MINIMUM) break;
                        }
                    }
                    
                }
                
                // Do we have all we need?
                if (free.len() == count && _freePageCache.len() >= SFFS_FREECACHE_MINIMUM) break;
            }
        }
        
        // Now, what have we got?
        if (free.len() < count) {
            server.error(format("Requested %d pages but only found %d.", count, free.len()))
            throw "Insufficient free space, storage full";
        } else if (noRequired == null) {
            // No parameter was set, so give them the first and only item
            return free[0];
        } else {
            // Otherwise give the caller the array
            return free; 
        }
    }

    
    //--------------------------------------------------------------------------
    function _gc_scan() {
        
        _enable();
        
        local erased = blob(_sectors);
        local free = blob(_sectors);
        local used = blob(_sectors);
        local pagesErasedTotal = 0, pagesFreeTotal = 0, pagesUsedTotal = 0;

        // Scan the object lookup tables in each block, working out what is in each sector
        for (local b = 0; b < _blocks; b++) {
            
            // Read the lookup table
            local block = _start + (b * SFFS_BLOCK_SIZE);
            local lookupData = _readLookupPage(block);
            local pagesErased = 0, pagesFree = 0, pagesUsed = 0;
            
            // Skip the lookup sector in each block
            used.writen(0, 'b');
            erased.writen(0, 'b');
            free.writen(0, 'b');

            // Read the remaining 
            for (local i = 0; i < lookupData.count; i++) {

                local lookup = _getLookupData(lookupData, i);
                local sector = _getSectorFromAddr(lookup.page);

                if (lookup.stat == SFFS_LOOKUP_STAT_ERASED) {
                    pagesErased++;
                } else if (lookup.stat == SFFS_LOOKUP_STAT_FREE) {
                    pagesFree++;
                } else {
                    pagesUsed++;
                }

                if (sector == 4096 && lookup.stat != SFFS_LOOKUP_STAT_FREE) {
                    // server.log(format("page %d contains id %d at lookup offset %d", lookup.page, lookup.id, lookup.addr))
                }
                if ((lookup.page + SFFS_PAGE_SIZE) % SFFS_SECTOR_SIZE == 0) {
                    
                    // The sector is over, write the counts to the blobs
                    used.writen(pagesUsed, 'b');
                    erased.writen(pagesErased, 'b');
                    free.writen(pagesFree, 'b');
                    
                    pagesErasedTotal += pagesErased;
                    pagesFreeTotal += pagesFree;
                    pagesUsedTotal += pagesUsed;
                    
                    pagesFree = pagesErased = pagesUsed = 0;
                }
                
            }
        }
        
        _disable();

        // Work out if it is worth garbage collecting yet.
        server.log("-------[ Sector map ]-------")
        local sectors = ""; for (local i = 0; i < _sectors; i++) sectors += format("%2d ", i);
        server.log("   Sector: " + sectors);
        server.log(format("%4d %s: %s", pagesUsedTotal,   "Used", Utils.logBin(used)));
        server.log(format("%4d %s: %s", pagesErasedTotal, "Ersd", Utils.logBin(erased)));
        server.log(format("%4d %s: %s", pagesFreeTotal,   "Free", Utils.logBin(free)));
        server.log(format("Total space: %d / %d bytes free (%0.01f %%)", 
                pagesFreeTotal * SFFS_BODY_SIZE,
                _blocks * SFFS_BLOCK_SIZE,
                100.0 * (pagesFreeTotal * SFFS_BODY_SIZE) / (_blocks * SFFS_BLOCK_SIZE)
                ));
        server.log("----------------------------")
        
        return { erased = erased, free = free, used = used, 
                 pagesErasedTotal = pagesErasedTotal, pagesFreeTotal = pagesFreeTotal, pagesUsedTotal = pagesUsedTotal };
    }
    
    
    //--------------------------------------------------------------------------
    function gc(initCallback = null) {
        
        if (_openFiles.len() > 0) return server.error("Can't call gc() with open files");

        _enable();
        
        // Scan the storage collecting garbage stats
        local stats = _gc_scan();

        if (stats.pagesFreeTotal > 2 * SFFS_PAGES_PER_SECTOR || stats.pagesErasedTotal < 2 * SFFS_PAGES_PER_SECTOR) {
            server.log("Not worth garbage collecting yet.")
            // return _disable();
        }
        
        // Move all the used pages away from the erased pages
        for (local s = 0; s < _sectors; s++) {
            
            // Does this sector have anything to collect
            if (stats.erased[s] > 0 && /* stats.free[s] == 0 && */ stats.used[s] <= stats.pagesFreeTotal) {
                
                local sector = s * SFFS_SECTOR_SIZE;
                local block = _getBlockFromAddr(sector);
                
                if (stats.erased[s] > 0) {

                    // We may have stuff to move
                    // server.log(format("Moving %d pages from sector %d to recover %d erased pages", stats.used[s], s, stats.erased[s]))
                    
                }
                
                if (stats.used[s] > 0) {
                    
                    // Read the lookup data
                    local lookupData = _readLookupPage(block, true);
    
                    // Grab the free pages and copy into them
                    local freePages = _nextFreePage(stats.used[s], sector);
                    // server.log(format("Requested %d free pages and got %d", stats.used[s], freePages.len()))
    
                    // Skip straight to the sector's lookup
                    for (local i = 0; i < lookupData.count && stats.used[s] > 0; i++) {
            
                        local lookup = _getLookupData(lookupData, i);
                        
                        // This is not from the sector we are looking at 
                        if (_getSectorFromAddr(lookup.page) != sector) {
                            continue;
                        } 
                        
                        // server.log("Data for lookup of page " + lookup.page + " sector " + sector + " in block " + block + " stat " + lookup.stat);

                        // These aren't interesting pages
                        if (lookup.stat == SFFS_LOOKUP_STAT_FREE) {
                            // server.log(format("- Skipping empty page %d", lookup.page))
                            continue;
                        } else if (lookup.stat == SFFS_LOOKUP_STAT_ERASED) {
                            // server.log(format("- Skipping erased page %d", lookup.page))
                            continue;
                        }

                        // Pop a free page off the list
                        local freePage = freePages[0];
                        freePages.remove(0);

                        local s_free = _getSectorFromAddr(freePage) / SFFS_SECTOR_SIZE;
                        local s_lookup = _getSectorFromAddr(lookup.page) / SFFS_SECTOR_SIZE;

                        // Read the next page and if it is "used" then move it
                        if (lookup.stat == SFFS_LOOKUP_STAT_INDEX) {
                            
                            // server.log(format("+ Moving %s page %02x (sector %02x) to %02x (sector %02x)",  "index", lookup.page, s_lookup, freePage, s_free))
    
                            // Copy the data over
                            _copyPage(lookup.page, freePage, lookup);
                            
                            // Finally, erase the original page
                            _erasePage(lookup.page);
                            
                        } else if (lookup.stat == SFFS_LOOKUP_STAT_DATA) {
                            
                            // server.log(format("+ Moving %s page %02x (sector %02x) to %02x (sector %02x)", "data", lookup.page, s_lookup, freePage, s_free))

                            // Copy the data over
                            _copyPage(lookup.page, freePage, lookup);
                            
                            // Finally, erase the original page
                            _erasePage(lookup.page);
                            
                        } else {
                            continue;
                        }
                        
                        
                        // Adjust the sector counts
                        stats.used[s_free]++;
                        stats.used[s_lookup]--;
                        stats.erased[s_lookup]++;
                        stats.pagesErasedTotal++;
                        stats.pagesFreeTotal--;

                    }
                }
                
                // Now we can erase the sector and correct the lookup table
                if (stats.used[s] == 0 && stats.erased[s] > 0) {
                    
                    // server.log(format("+ Erasing sector %d (data at page %02x, lookup at page %02x)", s, sector, block));
                    
                    // Read in the old lookup table and erase the sector from it
                    local lookupData = _flash.read(block, 2 * SFFS_PAGE_SIZE);
                    local start = 2 * (sector - block) / SFFS_PAGE_SIZE;
                    
                    lookupData.seek(start);
                    for (local i = 0; i < SFFS_PAGES_PER_SECTOR; i++) {
                        lookupData.writen(SFFS_LOOKUP_FREE, 'w');
                    }

                    // Rewrite the lookup table
                    _flash.erasesector(block); imp.sleep(0.05);
                    lookupData.seek(0);
                    local res = _flash.write(block, lookupData, SFFS_SPIFLASH_VERIFY);
                    assert(res == 0);

                    // Perform the erase of the data sector
                    _flash.erasesector(sector); imp.sleep(0.05);

                    // Update the stats
                    stats.free[s] += stats.used[s] + stats.erased[s];
                    stats.used[s] = 0;
                    stats.erased[s] = 0;
                
                } else {
                    
                    // server.log(format("+ NOT Erasing sector %d because used %d erased %d", s, stats.used[s], stats.erased[s]));
                    
                }
            }
        }
        
        _disable();
        
        // Repair the tables because
        // repair();
        
        // Rescan the result
        _gc_scan();
        
        // Reinitialise the file system 
        init(initCallback);
        
    }
    
    
    //--------------------------------------------------------------------------
    function repair(initCallback = null) {
       
        if (_openFiles.len() > 0) return server.error("Can't call repair() with open files");
        
        _enable();
        
        // Repair the lookup tables by reading the contents of every page
        local lookupData = blob(2 * SFFS_PAGE_SIZE);
        local lookupWord;
        for (local b = 0; b < _blocks; b++) {
            
            // 
            local block = _start + (b * SFFS_BLOCK_SIZE);
            lookupData.seek(0);

            // Read the pages
            for (local p = 0; p < SFFS_PAGES_PER_BLOCK; p++) {

                local page = block + (p * SFFS_PAGE_SIZE);
                if (page < block + SFFS_SECTOR_SIZE) {
                    
                    // server.log("SKIP: " + block + ", " + page)
                    
                    // This is from the first sector, which is lookup data
                    lookupWord = SFFS_LOOKUP_ERASED;
                    
                } else {
                    
                    // server.log("KEEP: " + block + ", " + page)
                    
                    // This is a data or index page
                    local data = _readDataPage(page);
                    
                    if ((data.flags & SFFS_FLAGS_INDEX) == SFFS_FLAGS_INDEX) {
                        // This page has an index
                        lookupWord = data.id | SFFS_LOOKUP_MASK_INDEX;
                    } else if ((data.flags & SFFS_FLAGS_DATA) == SFFS_FLAGS_DATA) {
                        // This page has data
                        lookupWord = data.id;
                    } else if (data.flags == SFFS_FLAGS_FREE) {
                        // This page is free
                        lookupWord = SFFS_LOOKUP_FREE;
                    } else {
                        // This page is deleted
                        lookupWord = SFFS_LOOKUP_ERASED;
                    }
                }
                
                // Add the word to the lookup data
                lookupData.writen(lookupWord, 'w')

            }
            
            // Now erase and rewrite the lookup table
            server.log("Repairing block " + b)
            _flash.erasesector(block); imp.sleep(0.05);
            lookupData.seek(0);
            local res = _flash.write(block, lookupData, SFFS_SPIFLASH_VERIFY);
            assert(res == 0);
        }

        _disable();
        
        // Now reinitialise the FAT
        init(initCallback);

    }
    
    
    //--------------------------------------------------------------------------
    function _getBlockFromAddr(page) {
        return page - (page % SFFS_BLOCK_SIZE);
    }


    //--------------------------------------------------------------------------
    function _getSectorFromAddr(page) {
        return page - (page % SFFS_SECTOR_SIZE);
    }


    //--------------------------------------------------------------------------
    function _sortTableByValues(table) {
        
        // Load the table contents into an array
        local interim = [];
        foreach (k,v in table) {
            interim.push({ k = k, v = v });
        }
        // Sort the array by the key name
        interim.sort(function(first, second) {
            return first.v <=> second.v;
        });
        // Write them to a final array without the key
        local result = [];
        foreach (vv in interim) {
            result.push(vv.k);
        }
        return result;
    }
    

}

class SPIFlashFileSystem.File {

    _filesystem = null;
    _fileptr = null;
    _fname = null;
    _mode = null;
    _pos = 0;
    
    //--------------------------------------------------------------------------
    constructor(filesystem, fileptr, fname, mode) {
        _filesystem = filesystem;
        _fileptr = fileptr;
        _fname = fname;
        _mode = mode;
    }
    
    //--------------------------------------------------------------------------
    function close() {
        return _filesystem._close(_fileptr);
    }

    //--------------------------------------------------------------------------
    function info() {
        return _filesystem.info(_fileptr);
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
        return _pos == _filesystem.size(_fileptr);
    }

    //--------------------------------------------------------------------------
    function size() {
        return _filesystem.size(_fileptr);
    }

    //--------------------------------------------------------------------------
    function read(len = null) {
        local data = _filesystem._read(_fileptr, _pos, len);
        _pos += data.len();
        return data;
    }

    //--------------------------------------------------------------------------
    function write(data) {
        if (_mode == "r") throw "Can't write - file mode is 'r'";
        local bytesWritten = _filesystem._write(_fileptr, data);
        _pos += bytesWritten;
        return bytesWritten;
    }
}

