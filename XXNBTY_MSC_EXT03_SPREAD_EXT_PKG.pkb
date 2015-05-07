create or replace PACKAGE BODY XXNBTY_MSCEXT03_SPREAD_EXT_PKG
AS

  --------------------------------------------------------------------------------------------
  /*
  Package Name: XXNBTY_MSCEXT03_SPREAD_EXT_PKG
  Author's Name: Mark Anthony Geamoga
  Date written: 1-Dec-2014
  RICEFW Object: EXT03
  Description: This package will convert monthly/weekly past due forecast to daily bucket based on the defined working days from the manufacturing calendar.
  Program Style:
  Maintenance History:
  Date         Issue#  Name         		Remarks
  -----------  ------  -----------------	------------------------------------------------
  1-Dec-2014          Mark Anthony Geamoga  Initial Development
  24-Feb-2015		      Daniel Rodil			Modified to pass the bucket type and base forecast
                                        c_monthly_bucket_type to c_bucket_type and = NVL(p_mon_wk_bucket_type,3)
                                        c_base_forecast = NVL(p_base_forecast,5556984)
  3-Mar-2015		      Erwin Ramos			  Changed the SQLERRM to 2
  6-Mar-2015		      Erwin Ramos			  Update the apps.xxnbty_msc_denorms_deleted to xxnbty_msc_denorms_deleted.
  24-Mar-2015	141	    Erwin Ramos			  Added cursor c_del_denorms, INDEX and created INDEX to resolve defect 141.
  31-Mar-2015 143     Daniel Rodil			Modified to remove the criteria on the deletion on xxnbty_msc_denorms_deleted, as discussed with Ankit T.
  15-Apr-2015 150     Randyl Pulma      Updated to remove the rounding up and replace it with rounding up to 2 decimal places only.
  27-Apr-2015  INC960038   Daniel Rodil	    Updated to move the delete inside the main loop right after the insertion of the daily buckets.
										This would eliminate the issue of not being able to delete the converted weekly/monthly buckets if there are any issues encountered.
  
  */
  --------------------------------------------------------------------------------------------

PROCEDURE       past_due_forecast 
				( x_errbuf OUT VARCHAR2
                 ,x_retcode OUT VARCHAR2
                 ,p_calendar IN msc.msc_calendars.calendar_code%TYPE
				 ,p_mon_wk_bucket_type IN msd.msd_dp_scn_entries_denorm.bucket_type%TYPE
				 ,p_base_forecast IN msd.msd_dp_scn_entries_denorm.scenario_id%TYPE )

IS
  -- INC960038 27-Apr-2015
  TYPE forecast_rec			IS RECORD (
										DEMAND_PLAN_ID         NUMBER        
										,SCENARIO_ID            NUMBER        
										,DEMAND_ID              NUMBER        
										,BUCKET_TYPE            NUMBER        
										,START_TIME             DATE          
										,END_TIME               DATE          
										,QUANTITY               NUMBER        
										,SR_ORGANIZATION_ID     NUMBER        
										,SR_INSTANCE_ID         NUMBER        
										,SR_INVENTORY_ITEM_ID   NUMBER        
										,ERROR_TYPE             VARCHAR2(30)  
										,FORECAST_ERROR         NUMBER        
										,INVENTORY_ITEM_ID      NUMBER        
										,SR_SHIP_TO_LOC_ID      NUMBER        
										,SR_CUSTOMER_ID         NUMBER        
										,SR_ZONE_ID             NUMBER        
										,PRIORITY               NUMBER        
										,DP_UOM_CODE            VARCHAR2(10)  
										,ASCP_UOM_CODE          VARCHAR2(10)  
										,DEMAND_CLASS           VARCHAR2(240) 
										,UNIT_PRICE             NUMBER        
										,CREATION_DATE          DATE          
										,CREATED_BY             NUMBER        
										,LAST_UPDATE_LOGIN      NUMBER        
										,REQUEST_ID             NUMBER        
										,PROGRAM_APPLICATION_ID NUMBER        
										,PROGRAM_ID             NUMBER        
										,PROGRAM_UPDATE_DATE    DATE          
										,PF_NAME                VARCHAR2(250) 
										,MAPE_IN_SAMPLE         NUMBER        
										,MAPE_OUT_SAMPLE        NUMBER        
										,FORECAST_VOLATILITY    NUMBER        
										,AVG_DEMAND             NUMBER        
										,ROWID					VARCHAR2(100)
										);									
  TYPE forecast_type_rowid       IS TABLE OF forecast_rec; 
  -- End INC960038
  TYPE forecast_type       IS TABLE OF msd.msd_dp_scn_entries_denorm%ROWTYPE;

  l_mon_forecast        forecast_type_rowid;
  l_daily_forecast      forecast_type;

  l_max_demand_id       msd.msd_dp_scn_entries_denorm.demand_id%TYPE;
  l_demand_id           msd.msd_dp_scn_entries_denorm.demand_id%TYPE;
  l_ctr_inserted        NUMBER := 0;
  l_ctr_deleted         NUMBER := 0;
  l_ctr_no_calendar     NUMBER := 0;

  c_bucket_type 		NUMBER := NVL(p_mon_wk_bucket_type,3); --3        --constant variable for bucket type
  c_base_forecast       NUMBER := NVL(p_base_forecast,5556984); -- 5556984; --constant variable for base forecast
  c_limit				NUMBER := 10000;
  
  --cursor to retrieve monthly forecast for conversion
  CURSOR c_mon_forecast ( p_bucket_type  msd.msd_dp_scn_entries_denorm.bucket_type%TYPE,
                          p_scenario_id  msd.msd_dp_scn_entries_denorm.scenario_id%TYPE,
                          p_date_limit   msd.msd_dp_scn_entries_denorm.start_time%TYPE )
  IS SELECT a.*, a.rowid
       FROM msd.msd_dp_scn_entries_denorm a
      WHERE bucket_type = p_bucket_type
        AND scenario_id = p_scenario_id
        AND TRUNC(start_time) <= TRUNC(p_date_limit)
      ORDER BY start_time, quantity;

  --cursor that will generate daily forecast
  CURSOR c_daily_forecast ( p_monthly_forecast  forecast_rec, -- INC960038 27-Apr-2015  msd.msd_dp_scn_entries_denorm%ROWTYPE,
                            p_max_demand_id     msd.msd_dp_scn_entries_denorm.demand_id%TYPE,
                            p_calendar_code     msc.msc_calendars.calendar_code%TYPE)
  IS SELECT  p_monthly_forecast.demand_plan_id
      ,      p_monthly_forecast.scenario_id
      ,      (p_max_demand_id + ROWNUM)
      ,      1
      ,      b.calendar_date
      ,      b.calendar_date + 1
             --compute quantity per daily bucket type
             /*4/15/15 rvp: remove the rounding up and replace it with rounding up to 2 decimal places only. Defect 150 raised.*/
             /*old code: CEIL(p_monthly_forecast.quantity / MAX(ROWNUM) KEEP (DENSE_RANK LAST ORDER BY b.calendar_date) OVER (PARTITION BY a.sr_instance_id))*/
      ,      ROUND((p_monthly_forecast.quantity / MAX(ROWNUM) KEEP (DENSE_RANK LAST ORDER BY b.calendar_date) OVER (PARTITION BY a.sr_instance_id)),2)       
      ,      p_monthly_forecast.sr_organization_id
      ,      p_monthly_forecast.sr_instance_id
      ,      p_monthly_forecast.sr_inventory_item_id
      ,      p_monthly_forecast.error_type
      ,      p_monthly_forecast.forecast_error
      ,      p_monthly_forecast.inventory_item_id
      ,      p_monthly_forecast.sr_ship_to_loc_id
      ,      p_monthly_forecast.sr_customer_id
      ,      p_monthly_forecast.sr_zone_id
      ,      p_monthly_forecast.priority
      ,      p_monthly_forecast.dp_uom_code
      ,      p_monthly_forecast.ascp_uom_code
      ,      p_monthly_forecast.demand_class
      ,      p_monthly_forecast.unit_price
      ,      p_monthly_forecast.creation_date
      ,      p_monthly_forecast.created_by
      ,      p_monthly_forecast.last_update_login
      ,      p_monthly_forecast.request_id
      ,      p_monthly_forecast.program_application_id
      ,      p_monthly_forecast.program_id
      ,      p_monthly_forecast.program_update_date
      ,      p_monthly_forecast.pf_name
      ,      p_monthly_forecast.mape_in_sample
      ,      p_monthly_forecast.mape_out_sample
      ,      p_monthly_forecast.forecast_volatility
      ,      p_monthly_forecast.avg_demand
     FROM msc.msc_calendars a, msc.msc_calendar_dates b
    WHERE a.calendar_code = b.calendar_code
      AND a.calendar_code = p_calendar_code
      AND a.sr_instance_id = b.sr_instance_id
      AND a.sr_instance_id = p_monthly_forecast.sr_instance_id
      AND b.calendar_date BETWEEN p_monthly_forecast.start_time AND p_monthly_forecast.end_time
      AND b.seq_num IS NOT NULL --exclude weekends
    ORDER BY b.seq_num;
	
	--24-Mar-2015: cursor to delete all monthly forecast that have been converted to resolve defect 141
		
	CURSOR c_del_denorms  
	IS SELECT demand_id
			,bucket_type
			,scenario_id
			,sr_instance_id
			,sr_organization_id
			,sr_inventory_item_id
      ,demand_plan_id
      ,start_time
       FROM xxnbty_msc_denorms_deleted;
   
	  TYPE del_denorms IS TABLE OF  c_del_denorms%ROWTYPE;
	    l_del_denorms       del_denorms;

	  l_step number;  
	  l_mess varchar2(500);
                  
BEGIN
  l_step := 1;
  --delete backup but remain at least two months backup
  DELETE
    FROM xxnbty_msc_denorms_deleted;
  FND_CONCURRENT.AF_COMMIT;
  
  /* 31-Mar-2015 drodil defect 143
   WHERE start_time < (SELECT ADD_MONTHS(MAX(start_time),-1)      --get latest month exported but not greater than SYSDATE minus 1 month
                         FROM msd.msd_dp_scn_entries_denorm
                        WHERE bucket_type = c_bucket_type --Monthly/weekly bucket type
                          AND scenario_id = c_base_forecast       --Base Forecast
                          AND TRUNC(start_time) <= TRUNC(SYSDATE));  
  */
  
  l_step := 2;
  --get maximum demand id
  SELECT NVL(MAX(demand_id),0)
    INTO l_max_demand_id
    FROM msd.msd_dp_scn_entries_denorm;

  l_demand_id := l_max_demand_id;

  l_step := 3;
  --select all monthly past due forecast
  OPEN c_mon_forecast ( c_bucket_type, --Monthly/weekly bucket type
                        c_base_forecast,       --Base Forecast
                        SYSDATE                --limit to current and previous months
                      );
  LOOP
  FETCH c_mon_forecast BULK COLLECT INTO l_mon_forecast LIMIT c_limit;
    FOR i IN 1..l_mon_forecast.COUNT
    LOOP
      --select all calendar dates for the month excluding all weekends and other exceptions
      OPEN c_daily_forecast ( l_mon_forecast(i),
                              l_demand_id,
                              p_calendar
                            );
      LOOP
      FETCH c_daily_forecast BULK COLLECT INTO l_daily_forecast LIMIT c_limit;

        l_step := 4;
        FORALL ii IN 1..l_daily_forecast.COUNT
          INSERT INTO msd.msd_dp_scn_entries_denorm VALUES l_daily_forecast(ii);

      l_demand_id := l_demand_id + l_daily_forecast.COUNT; --update demand id for the next monthly forecast

      IF l_daily_forecast.COUNT = 0 THEN
        l_ctr_no_calendar := l_ctr_no_calendar + 1; --count all monthly forecast with no calendar setup
      ELSE
        l_step := 5;
        --backup monthly past due forecast before deleting
        -- INC960038 27-Apr-2015 INSERT INTO xxnbty_msc_denorms_deleted VALUES l_mon_forecast(i);
		INSERT INTO xxnbty_msc_denorms_deleted (DEMAND_PLAN_ID        
												,SCENARIO_ID           
												,DEMAND_ID             
												,BUCKET_TYPE           
												,START_TIME            
												,END_TIME              
												,QUANTITY              
												,SR_ORGANIZATION_ID    
												,SR_INSTANCE_ID        
												,SR_INVENTORY_ITEM_ID  
												,ERROR_TYPE            
												,FORECAST_ERROR        
												,INVENTORY_ITEM_ID     
												,SR_SHIP_TO_LOC_ID     
												,SR_CUSTOMER_ID        
												,SR_ZONE_ID            
												,PRIORITY              
												,DP_UOM_CODE           
												,ASCP_UOM_CODE         
												,DEMAND_CLASS          
												,UNIT_PRICE            
												,CREATION_DATE         
												,CREATED_BY            
												,LAST_UPDATE_LOGIN     
												,REQUEST_ID            
												,PROGRAM_APPLICATION_ID
												,PROGRAM_ID            
												,PROGRAM_UPDATE_DATE   
												,PF_NAME               
												,MAPE_IN_SAMPLE        
												,MAPE_OUT_SAMPLE       
												,FORECAST_VOLATILITY   
												,AVG_DEMAND            )
		VALUES  (l_mon_forecast(i).DEMAND_PLAN_ID        
				,l_mon_forecast(i).SCENARIO_ID           
				,l_mon_forecast(i).DEMAND_ID             
				,l_mon_forecast(i).BUCKET_TYPE           
				,l_mon_forecast(i).START_TIME            
				,l_mon_forecast(i).END_TIME              
				,l_mon_forecast(i).QUANTITY              
				,l_mon_forecast(i).SR_ORGANIZATION_ID    
				,l_mon_forecast(i).SR_INSTANCE_ID        
				,l_mon_forecast(i).SR_INVENTORY_ITEM_ID  
				,l_mon_forecast(i).ERROR_TYPE            
				,l_mon_forecast(i).FORECAST_ERROR        
				,l_mon_forecast(i).INVENTORY_ITEM_ID     
				,l_mon_forecast(i).SR_SHIP_TO_LOC_ID     
				,l_mon_forecast(i).SR_CUSTOMER_ID        
				,l_mon_forecast(i).SR_ZONE_ID            
				,l_mon_forecast(i).PRIORITY              
				,l_mon_forecast(i).DP_UOM_CODE           
				,l_mon_forecast(i).ASCP_UOM_CODE         
				,l_mon_forecast(i).DEMAND_CLASS          
				,l_mon_forecast(i).UNIT_PRICE            
				,l_mon_forecast(i).CREATION_DATE         
				,l_mon_forecast(i).CREATED_BY            
				,l_mon_forecast(i).LAST_UPDATE_LOGIN     
				,l_mon_forecast(i).REQUEST_ID            
				,l_mon_forecast(i).PROGRAM_APPLICATION_ID
				,l_mon_forecast(i).PROGRAM_ID            
				,l_mon_forecast(i).PROGRAM_UPDATE_DATE   
				,l_mon_forecast(i).PF_NAME               
				,l_mon_forecast(i).MAPE_IN_SAMPLE        
				,l_mon_forecast(i).MAPE_OUT_SAMPLE       
				,l_mon_forecast(i).FORECAST_VOLATILITY   
				,l_mon_forecast(i).AVG_DEMAND);            		
        l_ctr_deleted := l_ctr_deleted + 1; --count all backed up monthly forecast
		
		-- INC960038 27-Apr-2015 
		DELETE FROM msd.msd_dp_scn_entries_denorm mdsed WHERE mdsed.rowid = l_mon_forecast(i).rowid;

	  END IF;

      EXIT WHEN c_daily_forecast%NOTFOUND;
      END LOOP;
      CLOSE c_daily_forecast;

    FND_CONCURRENT.AF_COMMIT;
    END LOOP;
    EXIT WHEN c_mon_forecast%NOTFOUND;
  END LOOP;
  CLOSE c_mon_forecast;
  
  l_step := 6;
  /*
	--24-Mar-2015: Added BULK delete to resolved the defect 141
  OPEN c_del_denorms;
  LOOP
      FETCH c_del_denorms BULK COLLECT INTO l_del_denorms LIMIT c_limit;

      FORALL i IN 1.. l_del_denorms.COUNT
         DELETE FROM msd.msd_dp_scn_entries_denorm a
          WHERE  a.demand_plan_id   = l_del_denorms(i).demand_plan_id
          AND   a.start_time = l_del_denorms(i).start_time
          AND   a.demand_id   = l_del_denorms(i).demand_id
          AND   a.bucket_type = l_del_denorms(i).bucket_type
          AND   a.scenario_id = l_del_denorms(i).scenario_id
          AND   a.sr_instance_id = l_del_denorms(i).sr_instance_id
          AND   a.sr_organization_id = l_del_denorms(i).sr_organization_id
          AND   a.sr_inventory_item_id = l_del_denorms(i).sr_inventory_item_id;
     
      FND_CONCURRENT.AF_COMMIT;

      EXIT WHEN c_del_denorms %NOTFOUND;
  END LOOP;
  CLOSE c_del_denorms;
  */
  
  -- INC960038 27-Apr-2015 comment out and include the delete after the insertion to the archive table xxnbty_msc_denorms_deleted
  --24-Mar-2015: Added INDEX and created INDEX to resolved the defect 141
  -- DELETE /*+ INDEX (a) */
  --  FROM msd.msd_dp_scn_entries_denorm a
  -- WHERE EXISTS (SELECT /*+ USE_NL (a b) INDEX (b) */ 1
  /* -- INC960038 start 
  FROM xxnbty_msc_denorms_deleted b
                  WHERE b.demand_id = a.demand_id
                    AND b.bucket_type = a.bucket_type
                    AND b.scenario_id = a.scenario_id
                    AND b.sr_instance_id = a.sr_instance_id
                    AND b.sr_organization_id = a.sr_organization_id
                    AND b.sr_inventory_item_id = a.sr_inventory_item_id);  
  
  FND_CONCURRENT.AF_COMMIT;
  */ -- end INC960038
  
  --delete all monthly forecast that have been converted
  /*
  DELETE
    FROM msd.msd_dp_scn_entries_denorm a
   WHERE EXISTS (SELECT 1
                   FROM xxnbty_msc_denorms_deleted b
                  WHERE b.demand_id = a.demand_id
                    AND b.bucket_type = a.bucket_type
                    AND b.scenario_id = a.scenario_id
                    AND b.sr_instance_id = a.sr_instance_id
                    AND b.sr_organization_id = a.sr_organization_id
                    AND b.sr_inventory_item_id = a.sr_inventory_item_id);
	*/	
  l_step := 7;
  l_ctr_inserted := l_demand_id - l_max_demand_id; --count all inserted records

  FND_FILE.PUT_LINE(FND_FILE.OUTPUT,'Total of '|| TO_CHAR(l_ctr_no_calendar, 'fm999,999,999,999,999') || ' record(s) has/have no calendar setup.');
  FND_FILE.PUT_LINE(FND_FILE.OUTPUT,'Total of '|| TO_CHAR(l_ctr_deleted, 'fm999,999,999,999,999') || ' record(s) has/have been converted and deleted.');
  FND_FILE.PUT_LINE(FND_FILE.OUTPUT,'Total of '|| TO_CHAR(l_ctr_inserted, 'fm999,999,999,999,999') || ' record(s) has/have been inserted in DENORM table.');

EXCEPTION
   WHEN OTHERS THEN
      l_mess := 'At step ['||l_step||'] SQLCODE [' ||SQLCODE|| '] - ' ||substr(SQLERRM,1,100);
      x_errbuf :=  l_mess;
      x_retcode := 2;
END past_due_forecast;

END XXNBTY_MSCEXT03_SPREAD_EXT_PKG;
/
show errors;
