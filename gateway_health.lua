local M = {}

function M.livez()
  return kong.response.exit(200, { status = "OK", service = "API Gateway" })
end

function M.readyz()
  -- Here we could potentially check Redis connectivity or other dependencies
  return kong.response.exit(200, { status = "OK", service = "API Gateway" })
end

return M
