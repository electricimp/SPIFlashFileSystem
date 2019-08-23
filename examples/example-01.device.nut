// MIT License
//
// Copyright 2016-2017 Electric Imp
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

#require "MessageManager.lib.nut:2.0.0"
#require "SPIFlashFileSystem.class.nut:3.0.0"

// Initialize using default settings
local mm = MessageManager();
spiffs <- SPIFlashFileSystem();
spiffs.init();

function getNextChunk(file = null, offset = 0, length = 1000) {

    // Prepare a request packet
    local request = {
        "url": "https://electricimp.com/public/v3/apple-touch-icon.png",
        "offset": offset,
        "length": length
    }

    // Send the request to the agent
    mm.send("http.get", request,
        {
            "onReply": function(msg, response) {
                local done = false;
                if (response && response.len() > 0) {
                    // We have a chunk of data

                    // Append it to the file
                    if (!file)
                        file = spiffs.open("electricimp.jpg", "w");
                    file.write(response)

                    if (response.len() == length) {
                        // Request the next chunk
                        getNextChunk(file, offset + length, length);
                    } else {
                        // We have more or less than we asked for. Best to stop
                        done = true;
                    }
                } else if (file) {
                    // We have finished or there is an error
                    done = true;
                }

                if (done) {
                    // Close the file
                    server.log("Received file of length: " + file.len())
                    file.close();
                }
            }.bindenv(this),
            "onFail" : function(err, message, retry) {
                server.error("Failed get next chunk. Retrying.")
                retry(10);
            }.bindenv(this)
        }
    ); // mm.send
}

// Erase previously downloaded file
if (spiffs.fileExists("electricimp.jpg")) {
    spiffs.eraseFile("electricimp.jpg");
}

// Function to recursively get the next chunk
// of the URL until it is finished
getNextChunk();
