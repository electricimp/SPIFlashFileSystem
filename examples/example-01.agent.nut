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

// Initialize using default settings
local mm = MessageManager();

mm.on("http.get", function(message, reply) {
	// Perform the download
	local request = message.data;
	local from = request.offset;
	local to = request.offset + request.length - 1
	local headers = { Range = format("bytes=%u-%u", from, to) };

	server.log("Requesting " + from + "-" + to + " from " + request.url);
	http.get(request.url, headers).sendasync(function(resp) {
        server.log("Response code: " + resp.statuscode + ", data length: " + resp.body.len());

	    if (resp.statuscode == 416 || resp.body.len() == 0) {
	        // No more data in that range
	        reply(null)
	    } else if (resp.statuscode < 300) {
	        // Success
	        reply(resp.body);
	    } else {
	        // Error
	        reply(false);
	    }

	});

});
