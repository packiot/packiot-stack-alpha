// Extracted verbatim from edge-node-red/subflows/SparkPlug_v1.10.39.1.json
// Node id:   1175dbcfce9b9ffa
// Node name: Calc Production Counters
// Node type: function (Node-RED)
//
// Node-RED function-node contract (what this JS sees at runtime):
//   INPUTS:
//     msg          — object with topic/payload/etc. from upstream Sparkplug decoder
//     flow.get(k)  — per-tab persistent store (packml_config lives here)
//     global.get(k) — cross-tab persistent store (modes lives here)
//     node.warn / node.error / node.log — logging
//   OUTPUTS:
//     return msg   — pass through with mutations; downstream receives
//     return null  — drop silently (Node-RED default no-op)
//
// The Go port in calc.go must replicate the same input→decision mapping.
// The State interface in state.go abstracts the flow/global reads.
//
// DO NOT EDIT. This file is the reference for the port + comparator.
// Update only when the upstream Node-RED node is edited AND
// the port + fixtures + comparator are re-validated.

// SP0.03 Cacl_Counters - Merged 0.01 and 0.02
/* Trigger : ProdProcessedCount 

The trigger, if is IN, OUT, or SCRAPED is defined in the topic as ***TRIG.

p.e.: <ENTERPRISE>/<SITE>/<AREA>/<LINE>/<UNIT>/Admin/ProdConsumedCount/0/Unit***TRIG
*/

var d = new Date();
if (msg.timestamp) d = new Date(msg.timestamp); //6MST
var timestamp = d.getTime();
var timestamp_threshold = timestamp //0.38

        // [fixed] removed hardcoded 2022 timestamp that overrode PLC ts



var trigger;
var send_msg = false;
var send_msg_processed = true;
var send_msg_consumed = true;
var send_msg_defective = true;

var reset_line_scrap_counter = false;

var has_sector = false;					   

var status = 0;
// cut off PackIoT comands
var topicStr = msg.topic.split("***")[0];

// save in flow var with PackML topic as name
//global.set(topicStr, msg.payload);

var status_topic_name = ""



// IN CASE OF US OPERATOR UI, VERIFY THE UNIT MODE, IF IS 6 (SETUP) DON'T RUM THIS

var unit_mode = 1
var modes

if (global.get("modes")) {

    var topicArray = topicStr.split("/");     
    var mode_topic=topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+"/Status/UnitModeCurrent"

    modes = global.get("modes");
    
    modes.find(function(mode, index) {
        if ((mode.topic==mode_topic) && (mode.is_set == true) && (node.type == 6))  {
            unit_mode = 6;
        }
    })
}

///

var ProdConsumedCount
var ProdProcessedCount
var ProdDefectiveCount
let TopicProdConsumedCount
var TopicProdDefectiveCount
var TopicProdProcessedCount
var ProdProcessedCount_Last
var ProdConsumedCount_Last
var ProdDefectiveCount_Last



if (unit_mode == 1) {

    if (msg.cmd_trigger) {
        if (msg.topic.includes("ProdProcessedCount")) trigger = "ProdProcessedCount";
        if (msg.topic.includes("ProdConsumedCount")) trigger = "ProdConsumedCount";
        if (msg.topic.includes("ProdDefectiveCount")) trigger = "ProdDefectiveCount";
    
        // 
        

        switch(trigger) {
          case "ProdProcessedCount":
                ProdProcessedCount = parseInt(msg.payload);
                
                //### get the other sensors thru the flow vars
                TopicProdConsumedCount = topicStr.replace('ProdProcessedCount', 'ProdConsumedCount');
                TopicProdDefectiveCount = topicStr.replace('ProdProcessedCount', 'ProdDefectiveCount');
                TopicProdProcessedCount = topicStr;
                
                ProdProcessedCount_Last = parseInt(global.get(TopicProdProcessedCount));
                ProdConsumedCount_Last = parseInt(global.get(TopicProdConsumedCount));
                ProdConsumedCount = ProdConsumedCount_Last
                ProdDefectiveCount_Last = parseInt(global.get(TopicProdDefectiveCount));
                ProdDefectiveCount = ProdDefectiveCount_Last
                
                if (ProdProcessedCount_Last < ProdProcessedCount) 
                    send_msg = true;
                if (ProdProcessedCount_Last > ProdProcessedCount) {
                    ProdProcessedCount_Last = 0
                    reset_line_scrap_counter = true // v1.10.2
                    send_msg = true;
                }
            break;
          case "ProdConsumedCount":
                ProdConsumedCount = parseInt(msg.payload);
                
                //### get the other sensors thru the flow vars
                TopicProdProcessedCount = topicStr.replace('ProdConsumedCount', 'ProdProcessedCount');
                TopicProdDefectiveCount = topicStr.replace('ProdConsumedCount', 'ProdDefectiveCount');
                TopicProdConsumedCount = topicStr;
                
                ProdProcessedCount_Last = parseInt(global.get(TopicProdProcessedCount));
                ProdProcessedCount = ProdProcessedCount_Last
                ProdConsumedCount_Last = parseInt(global.get(TopicProdConsumedCount));
                ProdDefectiveCount_Last = parseInt(global.get(TopicProdDefectiveCount));
                ProdDefectiveCount = ProdDefectiveCount_Last
                
                if (ProdConsumedCount_Last < ProdConsumedCount) 
                    send_msg = true;
                if (ProdConsumedCount_Last > ProdConsumedCount) {
                    ProdConsumedCount_Last = 0
                    reset_line_scrap_counter = true // v1.10.2                    
                    send_msg = true;
                }
                //msg.debug_ProdConsumedCount_Last = ProdConsumedCount_Last;
                //msg.debug_ProdConsumedCount = ProdConsumedCount;
            break;
            case "ProdDefectiveCount":
                ProdDefectiveCount = parseInt(msg.payload);
                
                //### get the other sensors thru the flow vars
                TopicProdConsumedCount = topicStr.replace('ProdDefectiveCount', 'ProdConsumedCount');
                TopicProdProcessedCount = topicStr.replace('ProdDefectiveCount', 'ProdProcessedCount');
                TopicProdDefectiveCount = topicStr;
                
                ProdConsumedCount_Last = parseInt(global.get(TopicProdConsumedCount));
                ProdConsumedCount = ProdConsumedCount_Last
                ProdProcessedCount_Last = parseInt(global.get(TopicProdProcessedCount));
                ProdProcessedCount = ProdProcessedCount_Last
                ProdDefectiveCount_Last = parseInt(global.get(TopicProdDefectiveCount));
                
                if (ProdDefectiveCount_Last < ProdDefectiveCount) 
                    send_msg = true;
                if (ProdDefectiveCount_Last > ProdDefectiveCount) {
                    ProdDefectiveCount_Last = 0
                    send_msg = true;
                }
            break;
        
        } 
        
                
                var ProdProcessedIncremet = ProdProcessedCount - ProdProcessedCount_Last
                var ProdConsumedIncremet = ProdConsumedCount - ProdConsumedCount_Last
                var ProdDefectiveIncremet = ProdDefectiveCount - ProdDefectiveCount_Last       
        
                
                msg.ProdConsumedCount = ProdConsumedCount;
                msg.ProdConsumedCount_Last = ProdConsumedCount_Last;
                msg.ProdConsumedIncremet = ProdConsumedIncremet;
                msg.ProdProcessedCount = ProdProcessedCount;
                msg.ProdProcessedCount_Last = ProdProcessedCount_Last;
                msg.ProdProcessedIncremet = ProdProcessedIncremet;
                msg.ProdDefectiveCount = ProdDefectiveCount;
                msg.ProdDefectiveCount_Last = ProdDefectiveCount_Last;
                msg.ProdDefectiveIncremet = ProdDefectiveIncremet;
        
        
        //### calculate ProdDefectiveCount
        
        if (send_msg == true) {
        
            /*** IF Processing is required. ***TRIG is attached on the PackML topic. _xxx indicates the type of calculation
            ***/
            if (msg.topic.includes("***TRIG")) {
                //msg.debug_ProdConsumedCount = ProdConsumedCount;
                //msg.debug_ProdProcessedCount = ProdProcessedCount;
                //msg.debug_ProdDefectiveCount = ProdDefectiveCount;
            
                var count_zeros = 0;
            
            
            ////!!!!!! CHANGE if (ProdDefectiveCount <= 0) to null -> isNaN(ProdDefectiveCount). do it for all three below
            
            /*** CALCULATE  Scrap = Infeed + Outfeed
            ***/      
                ProdDefectiveCount = isNaN(ProdDefectiveCount) ? 0:ProdDefectiveCount; 
                
                if ((ProdDefectiveCount <= 0)  ||  msg.topic.includes("***TRIG_CS")) {
                    ProdDefectiveCount = ProdConsumedCount - ProdProcessedCount;
                    count_zeros++;
                }
                
             /*** CALCULATE Infeed = Outfeed + Scrap
             ***/  
                ProdConsumedCount = isNaN(ProdConsumedCount) ? 0:ProdConsumedCount; 
                    
                if (((ProdConsumedCount <= 0) && (count_zeros<1)) ||  msg.topic.includes("***TRIG_CI")) {
                    ProdConsumedCount = ProdProcessedCount + ProdDefectiveCount;
                    count_zeros++;
                }
                
             /*** CALCULATE Infeed = Outfeed
             ***/  
                if (msg.topic.includes("***TRIG_C=I")) {
                    ProdConsumedCount = ProdProcessedCount;
                    ProdConsumedCount_Last = ProdProcessedCount_Last;
                    ProdDefectiveCount = 0;
                }
                
             /*** CALCULATE Outfeed = Infeed
             ***/    
             
                if (msg.topic.includes("***TRIG_C=O")) {
                    ProdProcessedCount = ProdConsumedCount;
                    ProdProcessedCount_Last = ProdConsumedCount_Last
                    ProdDefectiveCount = 0;
                }
                
             /*** CALCULATE Outfeed with infeed and scrap 
             ***/
            
                ProdProcessedCount = isNaN(ProdProcessedCount) ? 0:ProdProcessedCount;
            
                if (msg.topic.includes("***TRIG_CO")) {
                    
                    /****** 
                     * 
                     * Important!
                     * tested with NR interface ethternet module to connect with plc.  (Granado)
                     * (node-red-contrib-cip-ethernet-ip : eth-ip in)
                     * 
                     * works with tags in order to first scrap tag than infeed tag
                     * 
                     */ 
                    
                    
                    if (global.get(TopicProdConsumedCount + "___IN_INCR") == "0" )  {
                        
                        //ProdProcessedCount = ProdConsumedCount - ProdDefectiveCount - global.get(TopicProdConsumedCount + "___IN_SCRAP") - (ProdDefectiveCount - ProdDefectiveCount_Last)
                        
                        ProdProcessedCount = ProdConsumedCount - 2 * ProdDefectiveCount - global.get(TopicProdConsumedCount + "___IN_SCRAP") + ProdDefectiveCount_Last
    
                    } 
                    
                    if (ProdConsumedCount - ProdConsumedCount_Last >= 0)
                         global.set(TopicProdConsumedCount + "___IN_INCR", ProdConsumedCount - ProdConsumedCount_Last);
                    else global.set(TopicProdConsumedCount + "___IN_INCR", 0);
                    
                    if (ProdDefectiveCount - ProdDefectiveCount_Last >= 0)
                         global.set(TopicProdDefectiveCount + "___IN_SCRAP", ProdDefectiveCount - ProdDefectiveCount_Last);
                    else global.set(TopicProdDefectiveCount + "___IN_SCRAP", 0);
                    
                    if ((ProdProcessedCount == ProdProcessedCount_Last) && (ProdDefectiveCount == ProdDefectiveCount_Last)) ProdProcessedCount = ProdProcessedCount + ProdConsumedCount - ProdConsumedCount_Last;
                }
            
            
            msg.debug_ProdProcessedCount_A = ProdProcessedCount;
            msg.debug_ProdProcessedCount_Last_A = ProdProcessedCount_Last;
            
            
                    ProdProcessedIncremet = ProdProcessedCount - ProdProcessedCount_Last 
                    ProdConsumedIncremet = ProdConsumedCount - ProdConsumedCount_Last
                    ProdDefectiveIncremet = ProdDefectiveCount - ProdDefectiveCount_Last 
        
        }    
        
                var topicArray = topicStr.split("/");  //6MST 
                var topic_unit = topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+"/"+topicArray[4]; //6MST
                
                if ( send_msg == true) {
                    
                    if (ProdDefectiveCount >= 0) 
                        global.set(TopicProdDefectiveCount, ProdDefectiveCount); 
                    else 
                        global.set(TopicProdDefectiveCount, 0);
                    
                    if (ProdConsumedCount >= 0)  {
                        global.set(TopicProdConsumedCount, ProdConsumedCount); 
                        
                        //6MST for Montebello, add increment to a costum counter, show and reset with operator ui
                        /*
                        if ( topic_unit === "MONTEBELLO/LEBANON/FCL/KC1::PRESS/TPR") {
                            
                           global.set("MONTEBELLO/LEBANON/FCL/KC1::PRESS/TPR___Custom_Counter", global.get("MONTEBELLO/LEBANON/FCL/KC1::PRESS/TPR___Custom_Counter") + ProdConsumedIncremet); 
                            
                        }
                        
                        if ( topic_unit === "MONTEBELLO/LEBANON/FCL/KC2::PRESS/TPR") {
                            
                           global.set("MONTEBELLO/LEBANON/FCL/KC2::PRESS/TPR___Custom_Counter", global.get("MONTEBELLO/LEBANON/FCL/KC2::PRESS/TPR___Custom_Counter") + ProdConsumedIncremet); 
                            
                        }*/
                        
                        
                        
                        
///////////////         
/// SET A VALUE TO AN EXTRA COUNTER FOR THIS UNIT IF 30770 IS SET 
///      aditional counter of this unit is 30772, sums the increment of the counter unit
///      if 30770 is set or true enables counting
/////////////
                        
                        if (global.get(topic_unit + "/Status/Parameter*30770*") === true) {
                            
                            
                            if (typeof global.get(topic_unit + "/Status/Parameter*30772*") === 'undefined')
                                global.set(topic_unit + "/Status/Parameter*30772*", ProdConsumedIncremet);
                            else 
                                global.set(topic_unit + "/Status/Parameter*30772*", global.get(topic_unit + "/Status/Parameter*30772*") + ProdConsumedIncremet);
                                
                                
                                        ////only for Montebello
                                        //global.set(topic_unit+"___Custom_Counter", global.get(topic_unit+"___Custom_Counter") + ProdConsumedIncremet); 
                        }
                        
                        
                        
                        
                      //  if (topic_unit.includes("::PRESS/TPR")) {
                            
                      //     global.set(topic_unit+"___Custom_Counter", global.get(topic_unit+"___Custom_Counter") + ProdConsumedIncremet); 
                            
                      //  }
                    }    
                     
                    else {
                        global.set(TopicProdConsumedCount, 0);
   //                     reset_line_scrap_counter = true;     // v1.10.2
                    }
                                       
                    if (ProdProcessedCount >= 0) 
                        global.set(TopicProdProcessedCount, ProdProcessedCount); 
                    else {
                        global.set(TopicProdProcessedCount, 0);
  //                      reset_line_scrap_counter = true;  // v1.10.2
                    }
                    
                    /*
                    global.set(TopicProdDefectiveCount, ProdDefectiveCount);
                    global.set(TopicProdConsumedCount, ProdConsumedCount);
                    global.set(TopicProdProcessedCount, ProdProcessedCount);    
                    */
                }
                
                msg.topic = msg.topic;
                msg.payload = msg.payload;
            
            
                
                
    /*** SPEED clac speed for ProdProcessedIncremet and 1 minute
    ***/        
                //var topicArray = topicStr.split("/");  //6MST 
                
                //7MST ini ,  verify if get speed from sensor or is calculated, if true it comes from the Client(PLC) as topic with the CurMachSpeed
                var ProdSpeed  = 0.000
                var topic_extern_cur_speed=topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+"/"+topicArray[4]+"/Status/Parameter*30761*" 
                
                topicArray[5] = "Status/CurMachSpeed"
                var topic_status_speed = topicArray.join("/")
                
                
                if (global.get(topic_extern_cur_speed)) {
                    
                    var CurMachSpeed =topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+"/"+topicArray[4]+"/Status/CurMachSpeed"
                    
                    if (typeof global.get(CurMachSpeed) !== 'undefined') ProdSpeed = global.get(CurMachSpeed);
                    
                } else {
                        
                    if ( (ProdConsumedIncremet > 0)) { //(ProdProcessedIncremet > 0) ||

                        var ts_speed_before = global.get(topic_status_speed+"___TS");
                        
                        global.set(topic_status_speed+"___TS" , timestamp);
                        
                        

                        
                        
                        //ProdSpeed =  Math.round(ProdConsumedIncremet / (timestamp - ts_speed_before)*100000) * 0.6
                        //ProdSpeed =  (ProdConsumedIncremet / Math.round((timestamp - ts_speed_before)/10000)*10) * 0.6  //7MST
                        ProdSpeed =  Math.round(ProdConsumedIncremet / (timestamp - ts_speed_before)*60000) //0.38
                       
                        var CurMachSpeed =topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+"/"+topicArray[4]+"/Status/CurMachSpeed"
                    
                        global.set(CurMachSpeed, ProdSpeed)
                    }
                }
                // 7MST end
    
    /*** Get vars for stauts calulation  nominal machine speed, threshold quant. in % and threshold in duration
    ***/ 
            //var topicArray = topicStr.split("/");     
            var topic_machspeed=topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+"/"+topicArray[4]+"/Status/MachSpeed"
            var topic_threshold_quant=topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+"/"+topicArray[4]+"/Status/Parameter*30750*"
            var topic_threshold_mode=topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+"/"+topicArray[4]+"/Status/Parameter30758" // 0.37
																																																	
    
            
            if ( typeof global.get(topic_machspeed) === 'undefined' )
                var machspeed = 0;  else machspeed = global.get(topic_machspeed); // nominal machine speed 

                
            if ( typeof global.get(topic_threshold_quant) === 'undefined' || global.get(topic_threshold_quant) === null )
                var threshold_quant = 0;  else threshold_quant = global.get(topic_threshold_quant); // minimum percent threshold for Holding 
global.set ("______DEBUG_AAAAAD", {topic_threshold_quant: topic_threshold_quant, threshold_quant: threshold_quant,  topic: TopicProdConsumedCount }  )                 
            if ( typeof global.get(topic_threshold_mode) === 'undefined' || global.get(topic_threshold_mode) === null )   // 0.37
            var threshold_mode = 0;  else threshold_mode = global.get(topic_threshold_mode); //threshold state mode; defines how and when enters or leave a state. Default = 0; 0: get mach. speed of last value; 4: calc  get avg  from last 2,5 minutes
                  
      
/*** FACTOR TO MULTIPY  COUNTER VALUE ****
***/       
        var counter_multiplier = 1
        
        var topic_counter_multiplier=topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+"/"+topicArray[4]+"/Status/Parameter*30710*" 
        if (global.get(topic_counter_multiplier)) counter_multiplier = global.get(topic_counter_multiplier);
        
        ProdConsumedIncremet = ProdConsumedIncremet * counter_multiplier;
        ProdProcessedIncremet = ProdProcessedIncremet * counter_multiplier;
        ProdDefectiveIncremet = ProdDefectiveIncremet * counter_multiplier;
        
        ProdSpeed = ProdSpeed * counter_multiplier; // 7MST              
                
    /*** build SparkPlug snippet
    ***/
                /*
                if ( ProdConsumedIncremet > 3 * machspeed || ProdProcessedIncremet > 3 * machspeed || ProdDefectiveIncremet > 3 * machspeed) 
                    send_msg = false;
                else 
                send_msg = true
                && ProdConsumedIncremet < 3 * machspeed
                && ProdProcessedIncremet < 3 * machspeed 
                && ProdDefectiveCount < 3 * machspeed
                */ 
                msg.machspeed = machspeed + " " + topic_machspeed
                
                msg.metrics = [];
                var i_obj = 0
                
                var ProdConsumed_set = false
                var ProdProcessed_set = false
                
                           
               
                send_msg = false

            var Obj_ProdConsumedCount
            //var TopicProdConsumedCount
            var Obj_ProdProcessedCount
                if (ProdConsumedIncremet > 0 && ProdConsumedCount >= 0 && (ProdSpeed < 3 * machspeed )) { //0.34
                    Obj_ProdConsumedCount =
                                    {
                                        "timestamp" : timestamp, // option
                                        "name" : TopicProdConsumedCount,
                                        "value" : ProdConsumedIncremet,
                                        "type" : "int32",
                                        "counter" : ProdConsumedCount,
                                        "timezone" : msg.SparkPlug_timezone
                                    }
                    
                    //Obj_ProdConsumedCount["faults"] = {"topic_threshold_quant" : topic_threshold_quant, "ProdSpeed":parseFloat(ProdSpeed).toFixed(1)};// {"debug" : 4} or nullmachspeed
                    //Obj_ProdConsumedCount["faults"] = {"ProdProcessedINCR" : ProdProcessedCount-ProdProcessedCount_Last, "ProdDefectiveCount":ProdDefectiveCount, "ProdDefectiveCount_Last": ProdDefectiveCount_Last};// {"debug" : 4} or nullmachspeed
                    
                     
                    if (!msg.topic.includes("***STATESPEED_THIS"))  Obj_ProdConsumedCount["curspeed"] = parseFloat(ProdSpeed).toFixed(1);
                   
                    
                    Obj_ProdConsumedCount = {...Obj_ProdConsumedCount, ...msg.SparkPlug_add_metrics}
                    
                    msg.metrics[i_obj] = Obj_ProdConsumedCount;
                   
                    if (!msg.topic.includes("***STATESPEED_THIS")) {
                                      
                            //machspeed * threshold_quant / 100
                            //msg.machspeed  = machspeed
                           // msg.threshold_quant = machspeed * threshold_quant / 100
                           
                           // 0.38
                           
                            var threshold_val =  machspeed * threshold_quant / 100
                            timestamp_threshold = timestamp
 global.set ("______DEBUG_AAAAAC", {machspeed: machspeed, threshold_quant: threshold_quant,  topic: TopicProdConsumedCount }  )                            
                            if (typeof global.get(topic_threshold_mode+"_6_Consumed_last_TS") === "undefined") global.set(topic_threshold_mode+"_6_Consumed_last_TS", timestamp)
                           
                            if (ProdSpeed >=  threshold_val && global.get(topic_threshold_mode+"_6_Consumed_last_TS")+150000 <= timestamp) {
                                global.set(topic_threshold_mode+"_6_Consumed_last_TS",timestamp)  // 0.38 last time when passed threshold
                                global.set(topic_threshold_mode+"_6_Consumed_last_counter_value", TopicProdConsumedCount)  // 0.38 last counter value when passed threshold
                            }
                            
                            
                            if (threshold_mode === 4){

                                // @ts-ignore
                                threshold_val = (ProdConsumedCount - global.get(topic_threshold_mode+"_6_Consumed_last_counter_value")) / (timestamp - global.get(topic_threshold_mode+"_6_Consumed_last_TS"))
                                
                                timestamp_threshold = global.get(topic_threshold_mode+"_6_Consumed_last_TS")   //?????
                            }                          
                            // 0.38 end
                            
global.set ("______DEBUG_AAAAAA", {ProdSpeed: ProdSpeed, threshold_val: threshold_val,  topic: TopicProdConsumedCount }  ) 
                            if (ProdSpeed >=  threshold_val) { // 0.38
                                status = 6
                                status_topic_name = TopicProdConsumedCount
                            }
                    }
                    send_msg = true
                    ProdConsumed_set = true
                }
                
                if (ProdProcessedIncremet > 0 && ProdProcessedCount >= 0 && (ProdSpeed < 3 *machspeed )) { //0.34
                    Obj_ProdProcessedCount =
                                    {
                                        "timestamp" : timestamp, // option     //timestamp_threshold 
                                        "name" : TopicProdProcessedCount,
                                        "value" : ProdProcessedIncremet,
                                        "type" : "int32",
                                        "counter" : ProdProcessedCount,
                                        "timezone" : msg.SparkPlug_timezone
                                    }
                                    
                    if (msg.topic.includes("***STATESPEED_THIS"))  Obj_ProdProcessedCount["curspeed"] = parseFloat(ProdSpeed).toFixed(2);
                    
                    Obj_ProdProcessedCount = {...Obj_ProdProcessedCount, ...msg.SparkPlug_add_metrics}
                    i_obj++;
                    msg.metrics[i_obj] = Obj_ProdProcessedCount;
                    
                    if (msg.topic.includes("***STATESPEED_THIS")) {
                        
                         // 0.38
                           
                            threshold_val =  machspeed * threshold_quant / 100
                            timestamp_threshold = timestamp
                            
                            if (typeof global.get(topic_threshold_mode+"_6_Consumed_last_TS") === "undefined") global.set(topic_threshold_mode+"_6_Consumed_last_TS", timestamp)
                           
                            if (ProdSpeed >=  threshold_val && global.get(topic_threshold_mode+"_6_Consumed_last_TS")+150000 <= timestamp) {
                                global.set(topic_threshold_mode+"_6_Consumed_last_TS",timestamp)  // 0.38 last time when passed threshold
                                global.set(topic_threshold_mode+"_6_Consumed_last_counter_value", TopicProdConsumedCount)  // 0.38 last counter value when passed threshold
                            }
                            
                       
                            if (threshold_mode === 4){

                                // @ts-ignore
                                threshold_val = (ProdConsumedCount - global.get(topic_threshold_mode+"_6_Consumed_last_counter_value")) / (timestamp - global.get(topic_threshold_mode+"_6_Consumed_last_TS"))
                                
                                timestamp_threshold = global.get(topic_threshold_mode+"_6_Consumed_last_TS")  // ?????
                            }                          
                            // 0.38 end
                    
global.set ("______DEBUG_AAAAAB", {ProdSpeed: ProdSpeed, threshold_val: threshold_val,  topic: TopicProdProcessedCount }  )    
                        if (ProdSpeed >=  threshold_val) {
                            status = 6
                            status_topic_name = TopicProdProcessedCount
                        }
                    }
                    send_msg = true
                    ProdProcessed_set = true
                } 
                
            
                if ((ProdDefectiveIncremet > 0) && (ProdDefectiveCount >= 0) && (ProdDefectiveIncremet < 3 * machspeed)) {  
                    var Obj_ProdDefectiveCount =
                                    {
                                        "timestamp" : timestamp, // option   
                                        "name" : TopicProdDefectiveCount,
                                        "value" : ProdDefectiveIncremet,
                                        "type" : "int32",
                                        "counter" : ProdDefectiveCount,
                                        "timezone" : msg.SparkPlug_timezone
                                    }
                                    
                    Obj_ProdDefectiveCount = {...Obj_ProdDefectiveCount, ...msg.SparkPlug_add_metrics}
                    i_obj++;
                    msg.metrics[i_obj] = Obj_ProdDefectiveCount;
                    send_msg = true
                } 
                
    /*** LINE GROSS NET, SPEED
    ***/  
                var send_line = false

                //var topic_line_val = global.get(topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+'/Status/Parameter30700') 
           // reset Line scrap counters when reset ProcessedCount or ConsumedCount from PLC
        /*    if (reset_line_scrap_counter == true) {
                global.set(topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+'/Admin/ProdDefectiveCount___PREVIOUS' , 0);
                global.set(topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+'/Admin/ProdDefectiveCount' , 0);
            }*/
 
																																														  
 
																																												
 
 
               /// send metrics for line or sectores if exists 5,MST 
                

                
                    var topic_line_valu_arr = topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+'/Status/Parameter30700'  //Parameter99000
                    var topic_line_is_set = false;
                    var topic_sector_is_set = false;

                
                var topic_line = topicArray[3];
 
                for (let j = 0; j < 2; j++) {
                    
                    topic_line_is_set = false;
                    
                    topic_line_valu_arr = topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topic_line+'/Status/Parameter30700'

                    if ((j == 0) && ((typeof global.get(topic_line_valu_arr) !== 'undefined' && (global.get(topic_line_valu_arr) !== null)))) {
                            topic_line_is_set = true;
                            
                            if (reset_line_scrap_counter == true) {
                                global.set(topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+'/Admin/ProdDefectiveCount___PREVIOUS' , 0);
                                global.set(topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+'/Admin/ProdDefectiveCount' , 0);
                            }
                    } 
                    
                    
                    if ((j == 1) && (topicArray[3].includes("::"))) {   // if has a sector set gross and net for line
                        
                        var line_name = topicArray[3].split("::");
                        topic_line = line_name[0];
                        
                        var topic_line_valu_arr = topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topic_line+'/Status/Parameter30700'  //Parameter99000
                        
                        if ((typeof global.get(topic_line_valu_arr) !== 'undefined' && (global.get(topic_line_valu_arr) !== null))) {
                            topic_line_is_set = true; 
                            
                                                        
                            if (reset_line_scrap_counter == true) {
                                global.set(topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topic_line+'/Admin/ProdDefectiveCount___PREVIOUS' , 0);
                                global.set(topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topic_line+'/Admin/ProdDefectiveCount' , 0);
                            }
                        } 
                    }
                    
                    
                //}
                
                
                
                
                //var topic_line_valu_arr = topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topic_line+'/Status/Parameter30700'  //Parameter99000
                
                var topics_enterprise_to_line = topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topic_line;
                
                 
                //if ( typeof global.get(topic_line_valu_arr) === 'undefined' || global.get(topic_line_valu_arr) === null) {} 
                //else 
                
                if ( topic_line_is_set === true) {           
                    //var topic_line_val = global.get(topic_line_valu_arr) 
                    var topic_line_val = global.get(topic_line_valu_arr).split(",");
                    
				
                    msg.topic_line_val_0 = topic_line_val[0]
                    msg.topic_line_val_L = topic_line_val[topic_line_val.length-1]
                    msg.topic_line_val_A = topicArray[7]
                
               
           
               

                var scrap_line_net = 0;
                var scrap_line_gross = 0;
                var scrap_line_counter = 0;
                
                var Obj_Line_Val

                    if ((ProdConsumed_set==true) && (topicArray[7] == topic_line_val[0]) ) {
                        Obj_Line_Val =
                                        {
                                            "timestamp" : timestamp, // option
                                            "name" : topics_enterprise_to_line +'/Admin/ProdConsumedCount',
                                            "value" : ProdConsumedIncremet,
                                            "type" : "int32",
                                            "counter" : ProdConsumedCount,
                                            "timezone" : msg.SparkPlug_timezone
                                        }
                                               
                                       
                        if (!msg.topic.includes("***STATESPEED_THIS"))  Obj_Line_Val["curspeed"] = parseFloat(ProdSpeed).toFixed(1);
                        
                        //Obj_Status["faults"] = {"topic_status" : topic_status+"___TS", "timestamp" : timestamp};// {"debug" : 4} or nullmachspeed
                                        
                        Obj_Line_Val = {...Obj_Line_Val, ...msg.SparkPlug_add_metrics}
                        i_obj++;
                        msg.metrics[i_obj] = Obj_Line_Val;
                        send_line = true
                        
                        if (global.get(topics_enterprise_to_line+'/Admin/ProdDefectiveCount')) {
                            scrap_line_counter = global.get(topics_enterprise_to_line+'/Admin/ProdDefectiveCount');
                        }
                        
                        global.set(topics_enterprise_to_line +'/Admin/ProdDefectiveCount' , scrap_line_counter + ProdConsumedIncremet);
                  
                        scrap_line_gross = ProdConsumedIncremet;
                    }
                 
			  
                    if ((ProdProcessed_set==true) && (topicArray[7] == topic_line_val[topic_line_val.length-1])) {
                        Obj_Line_Val =
                                    {
                                        "timestamp" : timestamp, // option
                                        "name" : topics_enterprise_to_line +'/Admin/ProdProcessedCount',
                                        "value" :  ProdProcessedIncremet,
                                        "type" : "int32",
                                        "counter" : ProdProcessedCount,
                                        "timezone" : msg.SparkPlug_timezone
                                    }
                          
                        //Obj_Status["faults"] = {"topic_status" : topic_status+"___TS", "timestamp" : timestamp};// {"debug" : 4} or nullmachspeed
                                        
                        Obj_Line_Val = {...Obj_Line_Val, ...msg.SparkPlug_add_metrics}
                        i_obj++;
                        msg.metrics[i_obj] = Obj_Line_Val;
                        
                        
                        
                        if (global.get(topics_enterprise_to_line+'/Admin/ProdDefectiveCount')) {
                            scrap_line_counter = global.get(topics_enterprise_to_line+'/Admin/ProdDefectiveCount');
                        }
                        
                        global.set(topics_enterprise_to_line+'/Admin/ProdDefectiveCount' , scrap_line_counter - ProdProcessedIncremet);
                        

   
                        scrap_line_net = ProdProcessedIncremet * (-1);
                    }
                    
                    
                    
                if (global.get(topics_enterprise_to_line+'/Admin/ProdDefectiveCount___TS')) {
                } else {
                    global.set(topics_enterprise_to_line+'/Admin/ProdDefectiveCount___TS', timestamp);
                }
            
                if (((scrap_line_net != 0) || (scrap_line_gross != 0)) && global.get(topics_enterprise_to_line+'/Admin/ProdDefectiveCount___TS') + 20 <= timestamp)  {
                    
                    scrap_line_counter = global.get(topics_enterprise_to_line+'/Admin/ProdDefectiveCount');
                    var scrap_line_counter___PREVIOUS = 0;
                    
                    if (global.get(topics_enterprise_to_line +'/Admin/ProdDefectiveCount___PREVIOUS')) {
                        scrap_line_counter___PREVIOUS = global.get(topics_enterprise_to_line+'/Admin/ProdDefectiveCount___PREVIOUS');
                    }
                    
                    global.set(topics_enterprise_to_line+'/Admin/ProdDefectiveCount___PREVIOUS' , scrap_line_counter);
                    
                    
                    
                    Obj_Line_Val =
                                {
                                    "timestamp" : timestamp, // option
                                    "name" : topics_enterprise_to_line+'/Admin/ProdDefectiveCount',
                                    "value" :  scrap_line_counter - scrap_line_counter___PREVIOUS,
                                    "type" : "int32",
                                    "counter" : scrap_line_counter,
                                    "timezone" : msg.SparkPlug_timezone
                                }
                    global.set(topics_enterprise_to_line+'/Admin/ProdDefectiveCount___TS', timestamp);
                   
                    
                    //Obj_Status["faults"] = {"topic_status" : topic_status+"___TS", "timestamp" : timestamp};// {"debug" : 4} or nullmachspeed
                                    
                    Obj_Line_Val = {...Obj_Line_Val, ...msg.SparkPlug_add_metrics}
                    i_obj++;
                    msg.metrics[i_obj] = Obj_Line_Val;
                    
                }                  
            }
                }
                
    /*** STATUS 
    ***/        
                var topicArray_name = status_topic_name.split("/");
                topicArray_name[5] = "Status/StateCurrent"
                var topic_status = topicArray_name.join("/")
    
                
                if (status == 6) global.set(topic_status+"___TS" , timestamp_threshold); // 0.38
    
                var line_sector=topicArray[3]    //7MST
                
                if (typeof topic_status !== 'undefined'){   //0.36
													   
                    if (topicArray[3].includes("::")) {
						line_sector=topicArray[3].split("::")[0];  //7MST
						has_sector = true
					}					 
					 
                }
                
    
   //var BLOCK = false
   
   
                if (global.get(topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+line_sector+'/Status/Parameter*30763*')!==true)  {  //7MST Disables automatic event creator (for cases when eventes comes from client) (true = disabled)
	 
												 
                    
                    
                     // 0.38 from below, Set new topic in ___STATUS_TOPICS Array for verifing status periodicly 
                        var new_status_topic = false
                        msg.status_topics___ = ""
                        
                        if ( typeof global.get("___STATUS_TOPICS") === 'undefined' || global.get("___STATUS_TOPICS") === null) 
                            global.set("___STATUS_TOPICS", []) 
                        
                        var status_topics = []
                        status_topics = global.get("___STATUS_TOPICS")
                        
                        //var x = 0
                        var i = 0
                        for ( var x in global.get("___STATUS_TOPICS")) {
                            if (String(topic_status)==String(global.get("___STATUS_TOPICS["+i+"]"))) new_status_topic=true
                            i = i + 1
                        }
                        if (new_status_topic==false) {
                            status_topics[i] = topic_status;
                            global.set("___STATUS_TOPICS", status_topics)     
                        }
																																 
                    
                    
                    //0.39
                    var state_mode_calc = 0
                    var state_mode_topic=topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+"/"+topicArray[4]+"/Status/Parameter*30758*"
  
                    if(typeof global.get(state_mode_topic) !== 'undefined') state_mode_calc = global.get(state_mode_topic)
                    
                    
                    
                    if (((status!= 0) && (status !== global.get(topic_status))) && state_mode_calc ===0) {   //0.39
        
                        global.set(topic_status , status);
                        
                      /*  //Set new topic in ___STATUS_TOPICS Array for verifing status periodicly 
                        var new_status_topic = false
                        msg.status_topics___ = ""
                        
                        if ( typeof global.get("___STATUS_TOPICS") === 'undefined' || global.get("___STATUS_TOPICS") === null) 
                            global.set("___STATUS_TOPICS", []) 
                        
                        var status_topics = []
                        status_topics = global.get("___STATUS_TOPICS")
                        
                        var x = 0
                        var i = 0
                        for ( x in global.get("___STATUS_TOPICS")) {
                            if (String(topic_status)==String(global.get("___STATUS_TOPICS["+i+"]"))) new_status_topic=true
                            i = i + 1
                        }
                        if (new_status_topic==false) {
                            status_topics[i] = topic_status;
                            global.set("___STATUS_TOPICS", status_topics)     
                        }*/
                            
                        var Obj_Status     
                        Obj_Status =
                                        {
                                            "timestamp" : timestamp_threshold, // + 1000, 0.40 // option //038
                                            "name" : topic_status,
                                            "value" : status,
                                            "type" : "int32",
                                            "timezone" : msg.SparkPlug_timezone
                                        }
                        
                        //Obj_Status["faults"] = {"topic_status" : topic_status+"___TS", "timestamp" : timestamp};// {"debug" : 4} or nullmachspeed
                                        
                        Obj_Status = {...Obj_Status, ...msg.SparkPlug_add_metrics}
                        i_obj++;
                        msg.metrics[i_obj] = Obj_Status;
                        
                        // state for line (sector, if sector)
                        
                        //if ((send_line==true)){   0.40
                      
                                   
                            // 0.37 SEND FOR LINE if origin isn't a sector, or sector if origin is a sector
                                    
                                    
                            var topic_line=topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+"/Status/Parameter30700" 
                            var line_positions
                            var line_position

                            if ( typeof global.get(topic_line) === 'undefined' || global.get(topic_line) === null )
                                        {}  else {
                                            line_positions = global.get(topic_line).split(","); //0.40
                                             line_position = line_positions[0] //0.40
                                        }
                            //0.40 ini
                            var topic_line_pos=topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+"/Status/Parameter30702"   
                            if ( typeof global.get(topic_line_pos) === 'undefined' || global.get(topic_line_pos) === null )
                                {}  else line_position = global.get(topic_line_pos);
                            //0.40 end 
                            
                            if (topicArray[7]==line_position ) send_line = true; //0.40
                           if ((send_line==true)){   //0.40
                           
                            if (topicArray[7]==line_position )  { //topicArray[8] 0.37 Montebello HW 
                            
                                 Obj_Status =
                                            {
                                                "timestamp" : timestamp_threshold,// + 2000, // option 0.38 0.40
                                                "name" : topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+topicArray[3]+'/Status/StateCurrent',
                                                "value" : status,
                                                "type" : "int32",
                                                "timezone" : msg.SparkPlug_timezone
                                            }
                                Obj_Status = {...Obj_Status, ...msg.SparkPlug_add_metrics}
                                i_obj++;
                                msg.metrics[i_obj] = Obj_Status;
                            }
                            
                            
                            // SEND FOR SECTOR if origin is a sector 0.36
                
                            var topic_line_sector=topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+line_sector+"/Status/Parameter30700" 
                        
                            if ( typeof global.get(topic_line_sector) === 'undefined' || global.get(topic_line_sector) === null )
                                {}  else {
                                    line_positions = global.get(topic_line_sector).split(",");
                                    line_position = line_positions[0]
                                }
                                
    
                             //0.37 line position by parameter 30702
         try {                  
                            var topic_line_pos=topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+line_sector+"/Status/Parameter30702"   
                            if ( typeof global.get(topic_line_pos) === 'undefined' || global.get(topic_line_pos) === null )
                                {}  else line_position = global.get(topic_line_pos);
                                
      
                            if (topicArray[7]==line_position && has_sector === true)  { //topicArray[8] 0.37 Montebello HW
                                
                                //i = i + 1
                                
                                Obj_Status =
                                    {
                                        "timestamp" : timestamp_threshold + 3000, // option 0.38
                                        "name" : topicArray[0]+"/"+topicArray[1]+"/"+topicArray[2]+"/"+line_sector+'/Status/StateCurrent',
                                        "value" : status,
                                        "type" : "int32"
                                    }
                                Obj_Status = {...Obj_Status, ...msg.SparkPlug_add_metrics}
                                i_obj++;
                                msg.metrics[i_obj] = Obj_Status;
                                
                            }
                         //0.36 end
                        } catch(e) {
    }                     
                        }
                        
                        send_msg = true
                    } 
                }
          
          
              // msg.metrics = [Obj_ProdConsumedCount, Obj_ProdProcessedCount, Obj_ProdDefectiveCount]
         
             
         
                // build SparkPlug snippet DELETE
                /*
                msg.PackML = {
                    ENTERPRISE: topicArray[0],
                    SITE: topicArray[1],
                    AREA: topicArray[2],
                    LINE: topicArray[3],
                    UNIT: topicArray[4],
                    Admin: topicArray[5],
                    ProdConsumedCount: ProdConsumedCount,
                    ProdProcessedCount: ProdProcessedCount,
                    ProdDefectiveCount: ProdDefectiveCount
                };
                */
                //msg.topic = "metrics";
        
                msg.payload = send_msg;
                
                msg.send_msg = send_msg;
                
                if ( send_msg == true) {
                    return msg;
                }
                
            //}
        //}
        }
    }
}return msg;