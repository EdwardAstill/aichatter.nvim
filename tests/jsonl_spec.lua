local h = require("tests.helpers")
local jsonl = require("aichatter.jsonl")

h.test("frames partial and multiple JSON lines", function()
  local values = {}
  local parser = jsonl.new(function(value)
    values[#values + 1] = value
  end)

  parser:push('{"id":1}\n{"method":"turn/')
  parser:push('completed"}\n')

  h.eq(2, #values)
  h.eq(1, values[1].id)
  h.eq("turn/completed", values[2].method)
end)

h.test("reports malformed JSON without dropping the following line", function()
  local values, errors = {}, {}
  local parser = jsonl.new(
    function(value)
      values[#values + 1] = value
    end,
    function(err)
      errors[#errors + 1] = err
    end
  )

  parser:push('not-json\n{"id":2}\n')

  h.eq(1, #errors)
  h.eq(2, values[1].id)
end)

h.test("reports an unterminated JSONL frame when finished", function()
  local errors = {}
  local parser = jsonl.new(function() end, function(err, frame)
    errors[#errors + 1] = { err = err, frame = frame }
  end)

  parser:push('{"id":3}')
  parser:finish()

  h.eq(1, #errors)
  h.eq("unterminated JSONL frame", errors[1].err)
  h.eq('{"id":3}', errors[1].frame)
end)
