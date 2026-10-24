import http.client

connection = http.client.HTTPConnection("127.0.0.1", 9813, timeout=2)
try:
    connection.request("GET", "/healthz")
    response = connection.getresponse()
    assert response.status == 200 and response.read(16) == b"ok\n"
finally:
    connection.close()
