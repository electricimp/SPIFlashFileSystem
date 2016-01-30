#require "bullwinkle.class.nut:2.0.1"
#require "SPIFlashFileSystem.class.nut:1.0.2"


// Function to recursively get the next chunk of the URL until it is finished
function getNextChunk(file = null, offset = 0, length = 1000) {

    // Prepare a request packet
    local request = {
        "url": "https://pbs.twimg.com/profile_images/435528858532470784/alH9RtCl_400x400.jpeg",
        "offset": offset,
        "length": length
    }

    // Send the request to the agent
    bull.send("http.get", request)

        .onReply(

            // We received a response
            function(message) {
                if (message.data) {
                    // We have a chunk of data
                    if (!file) file = spiffs.open("electricimp.jpg", "w");

                    // Write at the end of the file
                    file.write(message.data)

                    // Request the next chunk
                    getNextChunk(file, offset + length, length);
                } else {
                    // We have finished or there is an error
                    if (file) {
                        // Close the file
                        server.log("Received file of length: " + file.len())
                        file.close();
                        file = null;
                    }
                }
            }.bindenv(this)

        )

        .onFail(

            // The request timed out or failed, just log and retry
            function(err, message, retry) {
                server.error("Failed get next chunk. Retrying.")
                retry(10);
            }.bindenv(this)

        )

}

// Initialise everything
bull <- Bullwinkle();
spiffs <- SPIFlashFileSystem();
spiffs.init();

// Start the download
if (spiffs.fileExists("electricimp.jpg")) {
    spiffs.eraseFile("electricimp.jpg");
}
getNextChunk();
