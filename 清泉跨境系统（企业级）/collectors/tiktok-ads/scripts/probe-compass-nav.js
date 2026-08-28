/* 完整复制 scrape-product-traffic-page.js 的 parseNumber/matchProductHeader/parseCellMetric/extractMoneyAfterCurrency，
 * 对 EU 域 Arco 表逐列输出 header→field→td text→parseCellMetric 结果，定位 impressions 缺失 + title 误判。 */
(function () {
  function clean(t){return String(t==null?'':t).replace(/\s+/g,' ').trim();}
  function parseNumber(value){
    if(value==null||value==='')return null;
    if(typeof value==='number'&&isFinite(value))return value;
    var s=String(value).trim();
    if(!s||s==='-'||s==='—')return null;
    var pct=s.match(/^(-?[\d,]+(?:\.\d+)?)\s*%$/);
    if(pct){var p=Number(String(pct[1]).replace(/,/g,''));return isFinite(p)?p:null;}
    var km=s.match(/-?\s*[¥$€£￥]?\s*([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)\s*([KkMm万亿])/);
    if(km){var base=Number(String(km[1]).replace(/,/g,''));if(isFinite(base)){var u=km[2];if(u==='K'||u==='k')return base*1000;if(u==='M'||u==='m')return base*1000000;if(u==='万')return base*10000;if(u==='亿')return base*100000000;}}
    var m=s.match(/-?\s*[¥$€£￥]?\s*([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)/);
    if(m){var n0=Number(String(m[1]).replace(/,/g,''));if(isFinite(n0))return n0;}
    s=s.replace(/[,\s]/g,'').replace(/[¥$€£￥]/g,'').replace(/%/g,'');
    var n=Number(s);return isFinite(n)?n:null;
  }
  function extractMoneyAfterCurrency(t){var s=String(t||'');var m=s.match(/[£$€¥￥]\s*([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)/);if(m){var n=Number(String(m[1]).replace(/,/g,''));if(isFinite(n))return n;}return null;}
  function matchProductHeader(h){
    var t=clean(h).toLowerCase();if(!t)return null;
    if(/^action$|^操作$|^详情$|^details?$/.test(t))return null;
    if(/商品\s*id|product\s*id|\bid\b/.test(t)&&!/视频|video|card\s*name/.test(t))return 'productId';
    if(/曝光\s*到\s*成交|曝光.*转化|\bcvr\b|转化率|conversion\s*rate|view[\s\-]*to[\s\-]*paid|paid\s*rate|viewers?\s*to\s*paid/i.test(t))return 'cvr';
    if(/曝光\s*用户|曝光数?|impression|show|展示|viewers?\b|unique\s*viewers?|product\s*views?\b/i.test(t)&&!/paid|转化|rate|ctr|cvr/.test(t))return 'impressions';
    if(/点击|clicks?/.test(t)&&!/率|rate|ctr/.test(t))return 'clicks';
    if(/\bctor\b/i.test(t))return 'cvr';
    if(/\bctr\b|点击率|click-?through/.test(t))return 'ctr';
    if(/订单|orders?|销量|units?|sku\s*订单/.test(t)&&!/ctor|ctr|率|rate|金额|amount|avg|平均/i.test(t))return 'orders';
    if(/\bgmv\b|销售额|成交额|revenue/.test(t))return 'gmv';
    if(/渠道|channel|来源|source|流量来源/.test(t)&&!/resource/.test(t))return 'channel';
    if(t==='信息'||/^info$/i.test(t))return 'channel';
    if(/日\s*客户|客户数|customers?/.test(t))return 'customers';
    if(/商品卡\s*名称|product\s*card\s*name|商品名称|product\s*name|名称|title|name/.test(t)&&!/曝光|点击|gmv|订单|ctr|cvr|转化|viewer|paid|impression/.test(t))return 'title';
    if(/商品|product/.test(t)&&!/曝光|点击|gmv|订单|ctr|cvr|转化|viewer|paid|impression|card\s*analytics/.test(t))return 'title';
    return null;
  }
  function parseCellMetric(txt,field){
    var s=String(txt==null?'':txt);
    if(field==='gmv'){var mv=extractMoneyAfterCurrency(s);if(mv!=null)return mv;return parseNumber(s);}
    if(field==='ctr'||field==='cvr'){var pm=s.match(/([\d.]+)\s*%/);if(pm){var pv=Number(pm[1]);if(isFinite(pv))return pv;}return parseNumber(s);}
    var stripped=s.replace(/-?\d+(?:\.\d+)?\s*%/g,' ').replace(/[£$€¥￥]/g,' ');
    var nm=stripped.match(/([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)/);
    if(nm){var nv=Number(String(nm[1]).replace(/,/g,''));if(isFinite(nv))return nv;}
    return parseNumber(s);
  }
  var arcoHeader=document.querySelector('.theme-arco-table-header table, [class*="arco-table-header"] table');
  var arcoBody=document.querySelector('.theme-arco-table-body table, [class*="arco-table-body"] table');
  if(!arcoHeader||!arcoBody) return JSON.stringify({ok:false,err:'no arco tables',h:!!arcoHeader,b:!!arcoBody});
  var hThs=arcoHeader.querySelectorAll('thead th, tr th');
  var hFields=[];var hHeaders=[];
  for(var i=0;i<hThs.length;i++){hHeaders.push(clean(hThs[i].innerText||hThs[i].textContent||''));hFields.push(matchProductHeader(hHeaders[i]));}
  var bTrs=arcoBody.querySelectorAll('tbody tr');
  var firstRow=bTrs.length?bTrs[0].querySelectorAll('td'):[];
  var colMap=[];
  for(var c=0;c<hHeaders.length;c++){
    var tdText=c<firstRow.length?clean(firstRow[c].innerText||firstRow[c].textContent||''):'';
    var f=hFields[c];
    var parsed=f?parseCellMetric(tdText,f):null;
    colMap.push({col:c,header:hHeaders[c],field:f,td:tdText.slice(0,30),parsed:parsed});
  }
  return JSON.stringify({ok:true,url:location.href,thCount:hThs.length,rowTdCount:firstRow.length,colMap:colMap});
})();
