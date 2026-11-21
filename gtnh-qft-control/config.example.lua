-- Example config for gtnh-qft-control (/home/qft/config.cfg)
{
  armed = false,
  pollSec = 5,
  extLinkMode = "auto",
  aeAddr = "auto",
  maintFreeCpus = 2,
  maintPollSec = 10,
  maintGroup = "QFT",
  units = {
    {
      id = "qft_1",
      label = "QFT-1",
      enabled = true,
      controllerAddr = "",
      busAddr = "",
      hatchAddr = "",
      tier = 4,
      recipeId = "pt_metallic_powder",
      mode = "passive",
      targetStock = 0, -- 0 = 24/7 passive
      focusMode = "auto",
      focusCircuit = 1,
      boostNeptunium = "auto",
      boostFermium = "off",
    },
  },
  localRules = {},
}
