local H = { passed = 0, failed = 0 }
function H.equal(actual, expected, message)
    if actual ~= expected then error((message or 'values differ') .. (': expected %s, got %s'):format(tostring(expected), tostring(actual)), 2) end
    H.passed = H.passed + 1
end
function H.ok(value, message) H.equal(not not value, true, message) end
function H.finish()
    io.write(('qbinventory smoke: %d passed, %d failed\n'):format(H.passed, H.failed))
end
return H
