-- Inofficial Stripe Extension (www.stripe.com) for MoneyMoney
-- Fetches balances from Stripe API and returns them as transactions
--
-- Password: Stripe Secret API Key
--
-- Copyright (c) 2018 Nico Lindemann
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

WebBanking{version     = 1.1,
           url         = "https://api.stripe.com/",
           services    = {"Stripe Account"},
           description = "Fetches balances from Stripe API and returns them as transactions"}

local apiSecret
local account
local apiUrlVersion = "v1"

function SupportsBank (protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Stripe Account"
end

function InitializeSession (protocol, bankCode, username, username2, password, username3)
  account = username
  apiSecret = password
end

function ListAccounts (knownAccounts)
  local account = {
    name = "Stripe Account",
    accountNumber = account,
    type = AccountTypeGiro
  }

  return {account}
end

function RefreshAccount (account, since)
  return {balances=GetBalances(), transactions=GetTransactions(since)}
end

function StripeRequest (endPoint)
  local headers = {}

  headers["Authorization"] = "Bearer " .. apiSecret
  headers["Accept"] = "application/json"

  connection = Connection()
  content = connection:request("GET", url .. apiUrlVersion .. "/" .. endPoint, nil, nil, headers)
  json = JSON(content)
  
  local response = json:dictionary()
  if response["error"] then
    error("Stripe API error: " .. response["error"]["message"])
  end

  return json
end

function GetBalances ()
  local balances = {}

  local response = StripeRequest("balance"):dictionary()
  if response["available"] then
    stripeBalances = response["available"]

    for key, value in pairs(stripeBalances) do
      local balance = {}
      balance[1] = (value["amount"] / 100)
      balance[2] = string.upper(value["currency"])
      balances[#balances+1] = balance
    end
  end

  return balances
end

function GetTransactions (since)
  local transactions = {}
  local lastTransaction = nil
  local moreItemsAvailable
  local baseRequest = "balance_transactions?limit=100&created[gt]=" .. since .. "&expand[]=data.source"
  
  repeat
    local requestString = baseRequest
    if lastTransaction then
      requestString = requestString .. "&starting_after=" .. lastTransaction
    end

    stripeObject = StripeRequest(requestString):dictionary()
    moreItemsAvailable = stripeObject["has_more"]

    for key, value in pairs(stripeObject["data"]) do
      lastTransaction = value["id"]

      -- Determine booked status based on transaction status
      local booked
      if value["status"] == "available" then
        booked = true
      elseif value["status"] == "pending" then
        booked = false
      else
        error("Unexpected transaction status: " .. tostring(value["status"]))
      end

      local name = value["reporting_category"]

      -- Override the name if it's a charge transaction
      if value["reporting_category"] == "charge" and value["source"] and value["source"]["object"] == "charge" then
        if value["source"]["billing_details"] and value["source"]["billing_details"]["name"] then
          name = value["source"]["billing_details"]["name"]
        end
      end

      -- Get the purpose from the description
      local purpose = ""
      if value["description"] then
        purpose = value["description"]
      end

      -- Process metadata information for charge transactions
      local metadataString = ""
      if value["reporting_category"] == "charge" and value["source"] and value["source"]["object"] == "charge" and value["source"]["metadata"] then
        local metadata = {}
        for metaKey, metaValue in pairs(value["source"]["metadata"]) do
          -- Capitalize first character of key
          local capitalizedKey = metaKey:sub(1,1):upper() .. metaKey:sub(2)
          table.insert(metadata, capitalizedKey .. ": " .. metaValue)
        end
        if #metadata > 0 then
          metadataString = table.concat(metadata, ", ")
        end
      end

      -- Add the main transaction first
      local mainPurpose = purpose
      if metadataString ~= "" then
        if mainPurpose ~= "" then
          mainPurpose = mainPurpose .. "\n"
        end
        mainPurpose = mainPurpose .. metadataString
      end

      transactions[#transactions+1] = {
        bookingDate = value["created"],
        valueDate = value["available_on"],
        purpose = mainPurpose,
        name = name,
        endToEndReference = value["id"],
        amount = (value["amount"] / 100),
        currency = string.upper(value["currency"]),
        booked = booked
      }
      
      -- Add fee transactions if present
      if value["fee"] ~= 0 then
        for feeKey, feeValue in pairs(value["fee_details"]) do
          transactions[#transactions+1] = {
            bookingDate = value["created"],
            valueDate = value["available_on"],
            name = feeValue["description"],
            purpose = metadataString,  -- Only use metadata string for fees
            endToEndReference = value["id"],
            amount = (feeValue["amount"] / 100) * -1,
            currency = string.upper(feeValue["currency"]),
            booked = booked
          }
        end
      end
    end

  until(not moreItemsAvailable)

  return transactions
end

function EndSession ()
  -- Logout.
end
