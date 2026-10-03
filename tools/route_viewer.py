#!/usr/bin/env python3
"""Writes build/route_viewer.html: a Leaflet map of Resources/Courses/*.json for eyeballing routes and stations."""
import json, glob, os
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
courses = []
for f in sorted(glob.glob(os.path.join(root, "Resources", "Courses", "*.json"))):
    c = json.load(open(f))
    pts = c["points"]
    total = len(pts) - 1
    st = []
    for s in c["stations"]:
        i = min(total, round(s["km"] / c["distanceKm"] * total))
        st.append([pts[i][0], pts[i][1], s["fluid"], s["fuel"], f'{s["km"]:.1f} km {s["label"]}'])
    courses.append({"id": c["id"], "line": [p[:2] for p in pts[::4]], "st": st})
html = """<!doctype html><html><head><meta charset=utf-8><title>Route check</title>
<link rel=stylesheet href="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.css">
<script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.js"></script>
<style>html,body,#m{height:100%;margin:0}#bar{position:absolute;z-index:999;top:8px;left:50px;right:8px;background:#fff;padding:4px;font:12px sans-serif}</style></head>
<body><div id=bar></div><div id=m></div><script>
const R=__DATA__;const m=L.map('m');L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19}).addTo(m);
let layer=L.layerGroup().addTo(m);
function show(i){layer.clearLayers();const r=R[i];const pl=L.polyline(r.line,{color:'red',weight:4}).addTo(layer);
L.circleMarker(r.line[0],{radius:9,color:'green'}).addTo(layer);
r.st.forEach(s=>L.circleMarker([s[0],s[1]],{radius:5,color:s[3]?'orange':'blue',fillOpacity:1}).bindTooltip(s[4]).addTo(layer));
m.fitBounds(pl.getBounds());location.hash=r.id;}
document.getElementById('bar').innerHTML=R.map((r,i)=>`<button onclick="show(${i})">${r.id}</button>`).join(' ');
const h=location.hash.slice(1);show(Math.max(0,R.findIndex(r=>r.id===h)));
</script></body></html>"""
open(os.path.join(root, "build", "route_viewer.html"), "w").write(html.replace("__DATA__", json.dumps(courses)))
