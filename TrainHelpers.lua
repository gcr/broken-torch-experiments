require 'dp'
require 'optim'

TrainHelpers = {}

-- clear the intermediate states in the model before saving to disk
-- this saves lots of disk space
function sanitize(net)
   local list = net:listModules()
   for _,val in ipairs(list) do
         for name,field in pairs(val) do
            if torch.type(field) == 'cdata' then val[name] = nil end
            if name == 'homeGradBuffers' then val[name] = nil end
            if name == 'input_gpu' then val[name] = {} end
            if name == 'input' then val[name] = {} end
            if name == 'finput' then val[name] = {} end
            if name == 'gradOutput_gpu' then val[name] = {} end
            if name == 'gradOutput' then val[name] = {} end
            if name == 'fgradOutput' then val[name] = {} end
            if name == 'gradInput_gpu' then val[name] = {} end
            if name == 'gradInput' then val[name] = {} end
            if name == 'fgradInput' then val[name] = {} end
            if (name == 'output' or name == 'gradInput') then
               val[name] = field.new()
            end
         end
   end
end

function inspect(model)
   local list = model:listModules()
   local fields = {}
   for i, module in ipairs(list) do
      print("Module "..i.."------------")
      for n,val in pairs(module) do
         local str
         if torch.isTensor(val) then
            str = torch.typename(val).." of size "..val:numel()
         else
            str = tostring(val)
         end
         table.insert(fields,n)
         print("    "..n..": "..str)
      end
   end

   print("Unique fields:")
   print(_.uniq(fields))
end

local ExperimentHelper = torch.class('TrainHelpers.ExperimentHelper')
function ExperimentHelper:__init(config)
   self.model = config.model
   self.trainDataset = config.trainDataset
   self.epochCounter = 0
   self.batchCounter = 0
   self.batchSize = config.batchSize
   self.totalNumSeenImages = 0
   self.currentEpochSeenImages = 0
   self.currentEpochSize = 0
   self.callbacks = {}
   self.lossLog = {}
   self.preprocessFunc = config.preprocessFunc

   self.sgd_state = {
      learningRate = config.learningRate,
      --learningRateDecay = 1e-7,
      --weightDecay = 1e-5,
      momentum = config.momentum or 0,
      dampening = config.dampening or 0,
      nesterov = config.nesterov or false,
   }

   self.sampler = dp.RandomSampler{batch_size = self.batchSize,
                                   ppf = self.preprocessFunc
                                }
   if config.datasetMultithreadLoading > 0 then
      self.trainDataset:multithread(config.datasetMultithreadLoading)
      self.sampler:async()
   end

end
function ExperimentHelper:runEvery(nBatches, func)
   self.callbacks[nBatches] = func
end
function ExperimentHelper:printEpochProgressEvery(nBatches)
   self:runEvery(nBatches,
                 function()
                    xlua.progress(self.currentEpochSeenImages,
                                  self.currentEpochSize)
              end)
end
function ExperimentHelper:printAverageTrainLossEvery(nBatches)
   self:runEvery(nBatches,
                 function()
                     local loss = 0
                     local before,after = table.splice(self.lossLog, #self.lossLog-nBatches, nBatches)
                     for _, entry in ipairs(after) do
                         loss = loss + entry.loss
                     end
                     print("Average loss for batches "..(self.batchCounter-nBatches).."--"..self.batchCounter..":", loss/#after)
                 end
   )

end
function ExperimentHelper:trainEpoch()
   self.epochCounter = self.epochCounter + 1
   local epoch_sampler = self.sampler:sampleEpoch(self.trainDataset)
   local batch
   local l
   local epochSize
   local new_w
   while true do
       batch, self.currentEpochSeenImages, self.currentEpochSize = epoch_sampler(batch)
       collectgarbage(); collectgarbage()
       if not batch then
          break -- Epoch done
       end
      local inputs = batch:inputs():input()
      local targets = batch:targets():input()
      new_w, l = optim.sgd(function()
                              return eval(batch:inputs():input(),
                                          batch:targets():input())
                           end, weights, sgd_state)
      self.batchCounter = self.batchCounter + 1
      self.totalNumSeenImages = self.totalNumSeenImages + batch:targets():input():size(1)
      table.insert(self.lossLog, {loss=l[1], totalNumSeenImages=self.totalNumSeenImages})

      for frequency, func in pairs(self.callbacks) do
         if self.batchCounter % frequency == 0 then
             io.write("\027[K") -- clear line (useful for progress bar)
            func(self)
         end
      end
   end
end
