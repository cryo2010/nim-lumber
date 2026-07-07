## Traffic generator for demos/webserver.nim: requests /api/user once per
## second so the server demo has something to log. No lumber usage here.
##
## Run (in a second terminal, with the webserver demo running):
##   nim r demos/webclient.nim

import std/[asyncdispatch, httpclient]

proc main() {.async.} =
  let client = newAsyncHttpClient()
  while true:
    try:
      let resp = await client.getContent("http://localhost:8080/api/user")
      echo "Response: ", resp
    except CatchableError as e:
      echo "Error: ", e.msg
    await sleepAsync(1000)

waitFor main()
