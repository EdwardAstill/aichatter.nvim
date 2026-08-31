local function send(value)
  io.stdout:write(vim.json.encode(value) .. "\n")
  io.stdout:flush()
end

io.stderr:write("fake app server started\n")
io.stderr:flush()

for line in io.lines() do
  local message = vim.json.decode(line)
  if message.method == "initialize" then
    send({ id = message.id, result = {} })
  elseif message.method == "account/read" then
    send({
      id = message.id,
      result = {
        account = { type = "chatgpt" },
        refreshToken = message.params.refreshToken,
      },
    })
  elseif message.method == "initialized" then
    io.stderr:write("initialized\n")
    io.stderr:flush()
  end
end
