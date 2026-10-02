package clientdescriptor

// activePLC returns the descriptor as the generators should see it: PLC
// connections switched off (endpoint Enabled=false) are dropped together with
// every tag-map entry that reads them. Their configuration stays in the stored
// descriptor, so switching one back on is a single toggle. With nothing
// disabled it returns d itself (byte-identical output); with everything
// disabled the plc block is treated as absent.
func (d *Descriptor) activePLC() *Descriptor {
	if d.PLC == nil {
		return d
	}
	off := map[string]bool{}
	var keep []DescriptorPLCEndpoint
	for _, ep := range d.PLC.Endpoints {
		if ep.Enabled != nil && !*ep.Enabled {
			off[ep.Name] = true
			continue
		}
		keep = append(keep, ep)
	}
	if len(off) == 0 {
		return d
	}
	cp := *d
	if len(keep) == 0 {
		cp.PLC = nil
		return &cp
	}
	plc := *d.PLC
	plc.Endpoints = keep
	plc.S7TagMap = nil
	for _, m := range d.PLC.S7TagMap {
		if !off[m.Endpoint] {
			plc.S7TagMap = append(plc.S7TagMap, m)
		}
	}
	plc.ModbusTagMap = nil
	for _, m := range d.PLC.ModbusTagMap {
		if !off[m.Endpoint] {
			plc.ModbusTagMap = append(plc.ModbusTagMap, m)
		}
	}
	plc.OPCUATagMap = nil
	for _, m := range d.PLC.OPCUATagMap {
		if !off[m.Endpoint] {
			plc.OPCUATagMap = append(plc.OPCUATagMap, m)
		}
	}
	cp.PLC = &plc
	return &cp
}
