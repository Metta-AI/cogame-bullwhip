## The private decision view shared by every policy and training consumer.
import std/json
import sim

const MaxNotesLen* = 600

proc observationJson*(sim: Sim, slot: int): JsonNode =
  ## One seat's information, independent of the policy implementation.
  let stage = sim.roleOf[slot]
  var history = newJArray()
  for record in sim.history:
    var week = stageJson(record.stages[stage])
    week["order"] = %record.orders[stage]
    history.add(week)
  var heard = newJArray()
  for other in neighbours(stage):
    if sim.heard[other].len > 0:
      heard.add(%*{"stage": other, "name": sim.names[sim.seatOf[other]], "message": sim.heard[other]})
  var chain = newJArray()
  for other in 0 ..< Stages: chain.add(%sim.names[sim.seatOf[other]])
  %*{
    "stage": stage, "chain": chain,
    "name": sim.names[slot],
    "role": RoleNames[stage],
    "week": sim.week,
    "weeks": sim.config.weeks,
    "seat": stageJson(sim.stages[stage]),
    "history": history,
    "heard": heard,
    "notes": sim.notes[slot],
    "talk": sim.config.talk,
    "legal": {"orderMin": 0, "orderMax": MaxOrder,
      "sayMaxChars": MaxSayLen, "notesMaxChars": MaxNotesLen}
  }

