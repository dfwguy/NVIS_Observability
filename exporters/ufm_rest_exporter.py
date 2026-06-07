#!/usr/bin/env python3
"""UFM Enterprise REST API — Prometheus Exporter  port :9404"""

import os, time, argparse, logging, urllib3
from collections import defaultdict
from datetime import datetime
import requests
from prometheus_client import start_http_server
from prometheus_client.core import GaugeMetricFamily, REGISTRY

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger("ufm-exporter")

UFM_URL      = os.environ.get("UFM_URL",      "https://worker20.air-inside.nvidia.com:33735")
UFM_USER     = os.environ.get("UFM_USER",     "admin")
UFM_PASSWORD = os.environ.get("UFM_PASSWORD", "123456")
CLUSTER      = os.environ.get("UFM_CLUSTER",  os.environ.get("CLUSTER_NAME", "nvis-cluster"))

def ufm_get(path):
    try:
        r = requests.get(f"{UFM_URL}/ufmRest/{path}", auth=(UFM_USER, UFM_PASSWORD),
                         verify=False, timeout=30)
        if r.status_code == 200 and r.text.strip():
            return r.json()
        log.warning("GET %s -> HTTP %s", path, r.status_code)
    except Exception as e:
        log.error("GET %s failed: %s", path, e)
    return None

SEV_NUM = {"Info": 0, "Warning": 1, "Minor": 2, "Major": 3, "Critical": 4}

class UFMCollector:
    def collect(self):
        c = CLUSTER; t0 = time.time()
        scrape_ok  = GaugeMetricFamily("ufm_scrape_success","1 if endpoint scraped OK",labels=["cluster","endpoint"])
        g_srv      = GaugeMetricFamily("ufm_fabric_servers","Fabric server count by state",labels=["cluster","state"])
        g_sw       = GaugeMetricFamily("ufm_fabric_switches","Fabric switch count by state",labels=["cluster","state"])
        g_inv      = GaugeMetricFamily("ufm_fabric_inventory","Inventory count by type+severity",labels=["cluster","device_type","severity"])
        g_inv_tot  = GaugeMetricFamily("ufm_fabric_inventory_total","Total devices by type",labels=["cluster","device_type"])
        g_fw       = GaugeMetricFamily("ufm_fabric_fw_version_count","Devices per FW version",labels=["cluster","device_type","fw_version"])
        g_alm_tot  = GaugeMetricFamily("ufm_fabric_alarms_total","Total active alarms",labels=["cluster"])
        g_alm_sev  = GaugeMetricFamily("ufm_fabric_alarms_by_severity","Alarms by severity",labels=["cluster","severity"])
        g_alm_type = GaugeMetricFamily("ufm_fabric_alarms_by_type","Alarms by type name",labels=["cluster","alarm_name"])
        g_alm_sw   = GaugeMetricFamily("ufm_fabric_alarms_by_switch","Alarms per switch (top50)",labels=["cluster","switch_name"])
        g_alm_et   = GaugeMetricFamily("ufm_fabric_alarms_by_event_type","Alarms by event_type code",labels=["cluster","event_type"])
        g_sw_alm   = GaugeMetricFamily("ufm_switch_total_alarms","Alarms per switch",labels=["cluster","switch_name","guid","role","severity","state"])
        g_sw_sev   = GaugeMetricFamily("ufm_switch_severity_level","Numeric severity (0=Info..4=Critical)",labels=["cluster","switch_name","guid","role"])
        g_sw_info  = GaugeMetricFamily("ufm_switch_info","Switch metadata (value=1)",labels=["cluster","switch_name","guid","role","fw_version","severity","state","is_managed"])
        g_sw_role  = GaugeMetricFamily("ufm_switches_by_role","Switches by role+severity",labels=["cluster","role","severity"])
        g_dur      = GaugeMetricFamily("ufm_scrape_duration_seconds","Scrape duration",labels=["cluster"])
        g_evt_tot  = GaugeMetricFamily("ufm_fabric_events_total","Total events returned by UFM (last 100)",labels=["cluster"])
        g_evt_sev  = GaugeMetricFamily("ufm_fabric_events_by_severity","Events by severity",labels=["cluster","severity"])
        g_evt_cat  = GaugeMetricFamily("ufm_fabric_events_by_category","Events by category",labels=["cluster","category"])
        g_evt_name = GaugeMetricFamily("ufm_fabric_events_by_name","Events by name",labels=["cluster","event_name"])
        g_evt_info = GaugeMetricFamily("ufm_fabric_event_info",
            "Individual UFM event (value=unix timestamp)",
            labels=["cluster","event_id","name","severity","category","object_path","description"])

        # monitoring/resources
        res = ufm_get("monitoring/resources")
        if res:
            scrape_ok.add_metric([c,"monitoring/resources"],1)
            for k,v in res.get("Servers",{}).items():  g_srv.add_metric([c,k.lower()],float(v))
            for k,v in res.get("Switches",{}).items(): g_sw.add_metric([c,k.lower()],float(v))
        else: scrape_ok.add_metric([c,"monitoring/resources"],0)

        # monitoring/inventory
        inv = ufm_get("monitoring/inventory")
        if inv:
            scrape_ok.add_metric([c,"monitoring/inventory"],1)
            for dt,data in inv.items():
                g_inv_tot.add_metric([c,dt],float(data.get("Total",0)))
                for sev,cnt in data.get("Severity",{}).items(): g_inv.add_metric([c,dt,sev],float(cnt))
                for ver,cnt in data.get("Version",{}).items():  g_fw.add_metric([c,dt,ver],float(cnt))
        else: scrape_ok.add_metric([c,"monitoring/inventory"],0)

        # app/alarms/
        alarms = ufm_get("app/alarms/")
        if alarms is not None:
            scrape_ok.add_metric([c,"app/alarms/"],1)
            g_alm_tot.add_metric([c],float(len(alarms)))
            by_sev=defaultdict(int); by_type=defaultdict(int)
            by_sw=defaultdict(int);  by_et=defaultdict(int)
            for a in alarms:
                by_sev[a.get("severity","Unknown")]+=1
                by_type[a.get("name","Unknown")]+=1
                by_et[str(a.get("event_type","?"))]+=1
                parts=a.get("object_path","").split(" / ")
                sw=parts[1].replace("Switch: ","") if len(parts)>1 else "unknown"
                by_sw[sw]+=1
            for k,v in by_sev.items():  g_alm_sev.add_metric([c,k],float(v))
            for k,v in by_type.items(): g_alm_type.add_metric([c,k],float(v))
            for k,v in by_et.items():   g_alm_et.add_metric([c,k],float(v))
            for sw,cnt in sorted(by_sw.items(),key=lambda x:-x[1])[:50]:
                g_alm_sw.add_metric([c,sw],float(cnt))
        else:
            scrape_ok.add_metric([c,"app/alarms/"],0)
            g_alm_tot.add_metric([c],0.0)

        # resources/systems/
        systems = ufm_get("resources/systems/?rpp=800")
        if systems:
            scrape_ok.add_metric([c,"resources/systems/"],1)
            role_sev=defaultdict(int)
            for s in systems:
                if s.get("type")!="switch": continue
                name=s.get("system_name",s.get("name","?")); guid=s.get("guid","?")
                role=s.get("role","?"); sev=s.get("severity","Info")
                state=s.get("state","?"); fw=s.get("fw_version","?")
                mgd=str(s.get("is_managed",False)); alm=float(s.get("total_alarms",0))
                g_sw_alm.add_metric([c,name,guid,role,sev,state],alm)
                g_sw_sev.add_metric([c,name,guid,role],float(SEV_NUM.get(sev,0)))
                g_sw_info.add_metric([c,name,guid,role,fw,sev,state,mgd],1.0)
                role_sev[(role,sev)]+=1
            for (role,sev),cnt in role_sev.items():
                g_sw_role.add_metric([c,role,sev],float(cnt))
        else: scrape_ok.add_metric([c,"resources/systems/"],0)

        # app/events/ — last 100 fabric events
        events = ufm_get("app/events/")
        if events is not None:
            scrape_ok.add_metric([c,"app/events/"],1)
            g_evt_tot.add_metric([c],float(len(events)))
            by_sev=defaultdict(int); by_cat=defaultdict(int); by_name=defaultdict(int)
            for e in events:
                sev  = e.get("severity","Unknown")
                cat  = e.get("category","Unknown")
                name = e.get("name","Unknown")
                by_sev[sev]+=1; by_cat[cat]+=1; by_name[name]+=1
                # parse timestamp → unix epoch for sortable table
                raw_ts = e.get("timestamp","")
                try:
                    ts_unix = datetime.strptime(raw_ts, "%Y-%m-%d %H:%M:%S").timestamp()
                except Exception:
                    ts_unix = 0.0
                desc = (e.get("description") or "")[:120]
                path = e.get("object_path","")
                g_evt_info.add_metric(
                    [c, str(e.get("id","")), name, sev, cat, path, desc],
                    ts_unix)
            for k,v in by_sev.items():  g_evt_sev.add_metric([c,k],float(v))
            for k,v in by_cat.items():  g_evt_cat.add_metric([c,k],float(v))
            for k,v in by_name.items(): g_evt_name.add_metric([c,k],float(v))
        else:
            scrape_ok.add_metric([c,"app/events/"],0)
            g_evt_tot.add_metric([c],0.0)

        g_dur.add_metric([c],time.time()-t0)
        for m in [scrape_ok,g_srv,g_sw,g_inv,g_inv_tot,g_fw,
                  g_alm_tot,g_alm_sev,g_alm_type,g_alm_sw,g_alm_et,
                  g_sw_alm,g_sw_sev,g_sw_info,g_sw_role,
                  g_evt_tot,g_evt_sev,g_evt_cat,g_evt_name,g_evt_info,
                  g_dur]:
            yield m

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=9404)
    args = parser.parse_args()
    REGISTRY.register(UFMCollector())
    start_http_server(args.port)
    log.info("UFM REST exporter :%d  cluster=%s", args.port, CLUSTER)
    while True:
        time.sleep(60)
