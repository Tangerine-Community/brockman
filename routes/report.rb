#encoding: utf-8
require 'base64'
require 'date'
require_relative '../helpers/Couch'
require_relative '../utilities/countyTranslate'
require_relative '../utilities/zoneTranslate'
require_relative '../utilities/percentage'
require_relative '../utilities/pushUniq'


class Brockman < Sinatra::Base

  #
  # Start of report
  #

  get '/report/:group/:workflowIds/:year/:month/:county.:format?' do | group, workflowIds, year, month, county, format |

    format = "html" unless format == "json"
    
    countyId = county

    requestId = SecureRandom.base64

    TRIP_KEY_CHUNK_SIZE = 500

    couch = Couch.new({
      :host      => $settings[:dbHost],
      :login     => $settings[:login],
      :designDoc => $settings[:designDoc],
      :db        => group
    })

    puts $settings[:dbHost]
    puts $settings[:login]
    puts $settings[:designDoc]

    subjectLegend = { "english_word" => "English", "word" => "Kiswahili", "operation" => "Maths" } 

    #
    # get Group settings
    #
    groupSettings = couch.getRequest({ :doc => 'settings', :parseJson => true })
    groupTimeZone = groupSettings['timeZone'] 

    #
    # Get quota information
    # 
    begin
      reportSettings = couch.getRequest({ :doc => "report-aggregate-settings", :parseJson => true })
      result = couch.getRequest({ :doc => "report-aggregate-year#{year}month#{month}", :parseJson => true })
    rescue => e
      # the doc doesn't already exist
      puts e
      return invalidReport()
    end

    currentCounty         = nil
    currentCountyName     = nil

   
    #ensure that the county in the URL is valid - if not, select the first
    if result['visits']['byCounty'][countyId].nil?
      result['visits']['byCounty'].find { |countyId, county|
        currentCountyId   = countyId
        currentCounty     = county
        currentCountyName = county['name']
        true
      }
    else 
      currentCountyId   = countyId
      currentCounty     = result['visits']['byCounty'][countyId]
      currentCountyName = currentCounty['name']
    end

    #retrieve a county list for the select and sort it
    countyList = []
    result['visits']['byCounty'].map { |countyId, county| countyList.push county['name'] }
    countyList.sort!

    chartJs = "
      function titleize(str){
        return str.replace(/\\w\\S*/g, function(txt) {
          return txt.charAt(0).toUpperCase() + txt.substr(1).toLowerCase();
        }).replace(/apbet/gi, 'APBET');
      }

      var base = 'http://#{$settings[:host]}#{$settings[:basePath]}/'; // will need to update this for live development

      // called on document ready
      var initChart = function()
      {
        var TREND_MONTHS = 3;  // number of months to try to pull into trend
        var month        = #{month.to_i};  // starting month
        var year         = #{year.to_i}; // starting year
        var countyId  = '#{countyId}';

        var reportMonth = moment(new Date(year, month, 1));
      
        var quotas_link = '/#{group}/geography-quotas';



        dates[TREND_MONTHS]       = { month:month, year:year};
        dates[TREND_MONTHS].link  = base+'reportData/#{group}/report-aggregate-year#{year.to_i}month#{month.to_i}.json';
        
        var skipMonths = [-1,0,4,8,11,12];
        var skippedMonths = 0;
        // create links for trends by month
        for ( var i = TREND_MONTHS-1; i > 0; i-- ) {
          tgtMonth      = reportMonth.clone().subtract((TREND_MONTHS - i + 1 + skippedMonths), 'months');
          if(skipMonths.indexOf(tgtMonth.get('month')+1) != -1){
            tgtMonth = tgtMonth.subtract(++skippedMonths, 'months');
          }

          dates[i]      = { month:tgtMonth.get('month')+1, year:tgtMonth.get('year')};
          dates[i].link = base+'reportData/#{group}/report-aggregate-year'+dates[i].year+'month'+dates[i].month +'.json';
          console.log('generating date' + i)
        }
        
        // call the links in a queue and then execute the last function
        var q = queue();
        for(var j=1;j<dates.length;j++)
        {
          q.defer(d3.json,dates[j].link);
        }
        q.await(buildReportCharts);
      }



      var datasetScores = Array()
      var datasetObservationsPublic = Array();
      var datasetObservationsAPBET = Array();
      var dates = Array();
      var months = {
        1:'January',
        2:'February',
        3:'March',
        4:'April',
        5:'May',
        6:'June',
        7:'July',
        8:'August',
        9:'September',
        10:'October',
        11:'November',
        12:'December'
      };  
      
      function buildReportCharts()
      {
        console.log(arguments);
        // sort out the responses and add the data to the corresponding dates array
        for(var j=arguments.length-1;j>=0;j--)
        {
          if(j==0)
          {
            var error = arguments[j];
          }
          else
          {
            dates[j].data = arguments[j]; // need to change for live when not using a proxy
          }
        }
        
        var quota = null //{geography.to_json};

        // loop over data and build d3 friendly dataset 
        dates.forEach(function(el){
          var tmpset = Array();
	  console.log(el);
          for(var county in el.data.visits.byCounty)
          {
            var tmpCounty = titleize(county);
            var tmp = {
              County   : tmpCounty,
              MonthInt : el.month,
              Year     : el.year,
              Month    : months[el.month]
            };
            
            var tmpVisit = {};
            var countyVisits = safeRead(el.data.visits.byCounty[county], 'visits');
            var countyQuota = safeRead(el.data.visits.byCounty[county],'quota');
            if (countyVisits == 0 || countyQuota == 0){
              tmpVisit['Visit Attainment'] = 0;
            } else {
              tmpVisit['Visit Attainment'] = countyVisits / countyQuota * 100;
            }

            if(tmpCounty.search(/apbet/i) == -1){
              datasetObservationsPublic.push($.extend({}, tmp, tmpVisit));
            } else {
              datasetObservationsAPBET.push($.extend({}, tmp, tmpVisit));
            }

            if(isNaN(tmpVisit['Visit Attainment'])) delete tmpVisit['Visit Attainment'];
            
            tmp['English Score'] = safeRead(el.data.visits.byCounty[county].fluency,'english_word','sum')/safeRead(el.data.visits.byCounty[county].fluency,'english_word','size');
            if(isNaN(tmp['English Score'])) { delete tmp['English Score'] };

            tmp['Kiswahili Score'] = safeRead(el.data.visits.byCounty[county].fluency,'word','sum')/safeRead(el.data.visits.byCounty[county].fluency,'word','size');
            if(isNaN(tmp['Kiswahili Score'])) { delete tmp['Kiswahili Score'] };

            //tmp['Math Score'] = safeRead(el.data.visits.byCounty[county].fluency,'operation','sum')/safeRead(el.data.visits.byCounty[county].fluency,'operation','size');
            //if(isNaN(tmp['Math Score'])) { delete tmp['Math Score'] };

            
                          
            datasetScores.push(tmp);
          }
        })
        
        // Build the charts. 
        addChart(datasetScores, 'English Score', 'English Score', 'Correct Items Per Minute');
        addChart(datasetScores, 'Kiswahili Score', 'Kiswahili Score', 'Correct Items Per Minute');
        //addChart('Math Score', 'Maths Score', 'Correct Items Per Minute');
        addChart(datasetObservationsPublic, 'Visit Attainment', 'Classroom Observations (Public)','Percentage');
        addChart(datasetObservationsAPBET, 'Visit Attainment', 'Classroom Observations (APBET)','Percentage');
        $('#charts-loading').remove()

      }     

    
      function addChart(dataset, variable, title, xaxis)
      {
        // create the element that the chart lives in
        var domid = (new Date()).getTime();
        $('#charts').append('<div class=\"chart\"><h2 style=\"text-align:center;\">'+title+'</h2><div id=\"chartContainer'+domid+'\" /></div>');

        // start building chart object to pass to render function
        chartObject = new Object();
        chartObject.container = '#chartContainer'+domid;
        chartObject.height = 650;
        chartObject.width = 450;
        chartObject.data =  dataset;
        
        chartObject.plot = function(chart){

          // setup x, y and series
          var y = chart.addCategoryAxis('y', ['County','Month']);
          y.addOrderRule('County');
          y.addGroupOrderRule('MonthInt');

          var x = chart.addMeasureAxis('x', variable);

          var series = chart.addSeries(['Month'], dimple.plot.bar);
          series.addOrderRule('MonthInt');
          series.clusterBarGap = 0;
          
          // add the legend
          //chart.addLegend(chartObject.width-100, chartObject.height/2-25, 100,  150, 'left');
          chart.addLegend(60, 10, 400, 20, 'right');
        };
        
        // titles for x and y axis
        chartObject.yAxis = 'County';
        chartObject.xAxis = xaxis;
        
        // show hover tooltips
        chartObject.showHover = true;
        buildChart(chartObject);
      }
      
      function buildChart(chart)
      {
        var svg = dimple.newSvg(chart.container, chart.width, chart.height);

        //set white background for svg - helps with conversion to png
        //svg.append('rect').attr('x', 0).attr('y', 0).attr('width', chart.width).attr('height', chart.height).attr('fill', 'white');
          
        var dimpleChart = new dimple.chart(svg, chart.data);
        dimpleChart.setBounds(90, 30, chart.width-100, chart.height-100);
        chartObject.plot(dimpleChart);

        if(!chart.showHover)
        {
          dimpleChart.series[0].addEventHandler('mouseover', function(){});
          dimpleChart.series[0].addEventHandler('mouseout', function(){});
        }

        dimpleChart.draw();
        
        // x axis title and redraw bottom line after removing tick marks
        dimpleChart.axes[1].titleShape.text(chartObject.xAxis).style({'font-size':'11px', 'stroke': '#555555', 'stroke-width':'0.2px'});
        dimpleChart.axes[1].shapes.selectAll('line').remove();
        dimpleChart.axes[1].shapes.selectAll('path').attr('d','M90,1V0H'+String(chart.width-10)+'V1').style('stroke','#555555');
        if(!dimpleChart.axes[0].hidden)
        {
          // update y axis
          dimpleChart.axes[0].titleShape.text(chartObject.yAxis).style({'font-size':'11px', 'stroke': '#555555', 'stroke-width':'0.2px'});
          //dimpleChart.axes[0].gridlineShapes.selectAll('line').remove();
        }
        return dimpleChart;
      }
      
      function capitalize(string)
      {
          return string.charAt(0).toUpperCase() + string.slice(1);
      }
      
      //
      // Usage... for a nested structure
      // var test = {
      //    nested: {
      //      value: 'Read Correctly'
      //   }
      // };
      // safeRead(test, 'nested', 'value');  // returns 'Read Correctly'
      // safeRead(test, 'missing', 'value'); // returns ''
      //
      var safeRead = function() {
        var current, formatProperty, obj, prop, props, val, _i, _len;

        obj = arguments[0], props = 2 <= arguments.length ? [].slice.call(arguments, 1) : [];

        read = function(obj, prop) {
          if ((obj != null ? obj[prop] : void 0) == null) {
            return;
          }
          return obj[prop];
        };

        current = obj; 
        for (_i = 0, _len = props.length; _i < _len; _i++) {
          prop = props[_i];

          if (val = read(current, prop)) {
            current = val;
          } else {
            return '';
          }
        }
        return current;
      };


    "

    
    
    


    row = 0
    countyTableHtml = "
      <table>
        <thead>
          <tr>
            <th>County</th>
            <th class='custSort'>Number of classroom visits<a href='#footer-note-1'><sup>[1]</sup></a><br>
            <small>( Percentage of Target Visits)</small></th>
            #{reportSettings['fluency']['subjects'].map{ | subject |
              "<th class='custSort'>#{subjectLegend[subject]}<br>
                Correct per minute<a href='#footer-note-3'><sup>[3]</sup></a><br>
                #{"<small>( Percentage at KNEC benchmark<a href='#footer-note-4'><sup>[4]</sup></a>)</small>" if subject != "operation"}
              </th>"
            }.join}
          </tr>
        </thead>
        <tbody>
          #{ result['visits']['byCounty'].map{ | countyId, county |

            countyName      = county['name']
            visits          = county['visits']
            quota           = county['quota']
            sampleTotal     = 0

            "
              <tr>
                <td>#{titleize(countyName)}</td>
                <td>#{visits} ( #{percentage( quota, visits )}% )</td>
                #{reportSettings['fluency']['subjects'].map{ | subject |
                  #ensure that there, at minimum, a fluency category for the county
                  sample = county['fluency'][subject]
                  if sample.nil?
                    average = "no data"
                  else
                    if sample && sample['size'] != 0 && sample['sum'] != 0
                      sampleTotal += sample['size']
                      average = ( sample['sum'] / sample['size'] ).round
                    else
                      average = '0'
                    end

                    if subject != "operation"
                      benchmark = sample['metBenchmark']
                      percentage = "( #{percentage( sample['size'], benchmark )}% )"
                    end
                  end
                  "<td>#{average} <span>#{percentage}</span></td>"
                }.join}
              </tr>
            "}.join }
            <tr>
              <td>All</td>
              <td>#{result['visits']['national']['visits']} ( #{percentage( result['visits']['national']['quota'], result['visits']['national']['visits'] )}% )</td>
              #{reportSettings['fluency']['subjects'].map{ | subject |
                sample = result['visits']['national']['fluency'][subject]
                if sample.nil?
                  average = "no data"
                else
                  if sample && sample['size'] != 0 && sample['sum'] != 0
                    average = ( sample['sum'] / sample['size'] ).round
                  else
                    average = '0'
                  end

                  if subject != "operation"
                    benchmark = sample['metBenchmark']
                    percentage = "( #{percentage( sample['size'], benchmark )}% )"
                  end
                end
                "<td>#{average} <span>#{percentage}</span></td>"
              }.join}
            </tr>
        </tbody>
      </table>
    "

    zoneTableHtml = "
      <label for='county-select'>County</label>
        <select id='county-select'>
          #{
            result['visits']['byCounty'].map{ | countyId, county |
              "<option value='#{countyId}' #{"selected" if countyId == currentCountyId}>#{titleize(county['name'])}</option>"
            }.join("")
          }
        </select>
      <table>
        <thead>
          <tr>
            <th>Zone</th>
            <th class='custSort'>Number of classroom visits<a href='#footer-note-1'><sup>[1]</sup></a><br>
            <small>( Percentage of Target Visits)</small></th>
            #{reportSettings['fluency']['subjects'].select{|x|x!="3" && !x.nil?}.map{ | subject |
              "<th class='custSort'>
                #{subjectLegend[subject]}<br>
                Correct per minute<a href='#footer-note-3'><sup>[3]</sup></a><br>
                #{"<small>( Percentage at KNEC benchmark<a href='#footer-note-4'><sup>[4]</sup></a>)</small>" if subject != "operation"}
              </th>"
            }.join}
          </tr>
        </thead>
        <tbody>
          #{result['visits']['byCounty'][countyId]['zones'].map{ | zoneId, zone |

            row += 1

            zoneName = zone['name']
            visits = zone['visits']
            quota = zone['quota']
            met = zone['fluency']['metBenchmark']
            sampleTotal = 0
            
            # Do we still need this?
            #nonFormalAsterisk = if formalZones[zone.downcase] then "<b>*</b>" else "" end

          "
            <tr> 
              <td>#{zoneName}</td>
              <td>#{visits} ( #{percentage( quota, visits )}% )</td>
              #{reportSettings['fluency']['subjects'].select{|x|x!="3" && !x.nil?}.map{ | subject |
                sample = zone['fluency'][subject]
                if sample.nil?
                  average = "no data"
                else
                  
                  if sample && sample['size'] != 0 && sample['sum'] != 0
                    sampleTotal += sample['size']
                    average = ( sample['sum'] / sample['size'] ).round
                  else
                    average = '0'
                  end

                  if subject != 'operation'
                    benchmark = sample['metBenchmark']
                    percentage = "( #{percentage( sample['size'], benchmark )}% )"
                  end

                end

                "<td>#{average} <span>#{percentage}</span></td>"
              }.join}

            </tr>
          "}.join }
        </tbody>
      </table>
      <small>

      <ol>
        <li id='footer-note-1'><b>Numbers of classroom visits are</b> defined as TUSOME classroom observations that include all forms and all 3 pupils assessments, with at least 20 minutes duration, and took place between 7AM and 3.10PM of any calendar day during the selected month.</li>
        <li id='footer-note-2'><b>Targeted number of classroom visits</b> is equivalent to the number of class 1 teachers in each zone.</li>
        <li id='footer-note-3'><b>Correct per minute</b> is the calculated average out of all individual assessment results from all qualifying classroom visits in the selected month to date, divided by the total number of assessments conducted.</li>
        <li id='footer-note-4'><b>Percentage at KNEC benchmark</b> is the percentage of those students that have met the KNEC benchmark for either Kiswahili or English, and for either class 1 or class 2, out of all of the students assessed for those subjects.</li>
      </ol>
      </small>

    "


    html =  "
    <html>
      <head>
        <style>
          body{font-family:Helvetica;}
          #map-loading { width: 100%; text-align: center; background-color: #dddd99;}
          #map { clear: both; }
          div.chart { float: left; } 
          h1, h2, h3 
          {
            display: block;
            clear:both;
          }
        </style>

        <link rel='stylesheet' type='text/css' href='http://ajax.aspnetcdn.com/ajax/jquery.dataTables/1.9.4/css/jquery.dataTables.css'>
        <link rel='stylesheet' type='text/css' href='http://cdn.leafletjs.com/leaflet-0.7.2/leaflet.css'>
        <link rel='stylesheet' type='text/css' href='http://cdnjs.cloudflare.com/ajax/libs/leaflet.markercluster/0.4.0/MarkerCluster.css'>
        <link rel='stylesheet' type='text/css' href='http://cdnjs.cloudflare.com/ajax/libs/leaflet.markercluster/0.4.0/MarkerCluster.Default.css'>
        

        <script src='http://cdnjs.cloudflare.com/ajax/libs/moment.js/2.9.0/moment.min.js'></script>

        <script src='/javascript/base64.js'></script>
        <script src='http://code.jquery.com/jquery-1.11.0.min.js'></script>
        <script src='http://ajax.aspnetcdn.com/ajax/jquery.dataTables/1.9.4/jquery.dataTables.min.js'></script>
        <script src='http://cdn.leafletjs.com/leaflet-0.7.2/leaflet.js'></script>
        <script src='http://cdnjs.cloudflare.com/ajax/libs/leaflet.markercluster/0.4.0/leaflet.markercluster.js'></script>
        <script src='/javascript/leaflet/leaflet-providers.js'></script>
        <script src='/javascript/leaflet/leaflet.ajax.min.js'></script>

        <script src='http://d3js.org/d3.v3.min.js'></script>
        <script src='http://dimplejs.org/dist/dimple.v2.0.0.min.js'></script>
        <script src='http://d3js.org/queue.v1.min.js'></script>

        <script>

          #{chartJs}

          updateMap = function() {

            if ( window.markers == null || window.map == null || window.geoJsonLayer == null ) { return; }

            window.markers.addLayer(window.geoJsonLayer);
            window.map.addLayer(window.markers);
            $('#map-loading').hide();

          };

          var mapDataURL = new Array();
          mapDataURL['current'] = base+'reportData/#{group}/report-aggregate-geo-year#{year.to_i}month#{month.to_i}-#{countyId}.geojson';
          mapDataURL['all'] = new Array();

          mapDataURL['all']
          #{
            result['visits']['byCounty'].map{ | countyId, county |
              "mapDataURL['all'].push(base+'reportData/#{group}/report-aggregate-geo-year#{year.to_i}month#{month.to_i}-#{countyId}.geojson');
              "
            }.join("")
          }

          swapMapData = function(){
            window.geoJsonLayer.refresh(mapDataURL['all']);
            $('#map-loading').show();
          }
          
          //init a datatables advanced sort plugin
            jQuery.extend( jQuery.fn.dataTableExt.oSort, {
                'num-html-pre': function ( a ) {
                    var x = String(a).replace( /<[\\s\\S]*?>/g, '' );
                    if(String(a).indexOf('no data')!= -1){
                      x = 0;
                    }
                    return parseFloat( x );
                },
             
                'num-html-asc': function ( a, b ) {
                    return ((a < b) ? -1 : ((a > b) ? 1 : 0));
                },
             
                'num-html-desc': function ( a, b ) {
                    return ((a < b) ? 1 : ((a > b) ? -1 : 0));
                }
            } );
          $(document).ready( function() {

            initChart()
            

            $('table').dataTable( { 
              iDisplayLength :-1, 
              sDom : 't',
              aoColumnDefs: [
                 { sType: 'num-html', aTargets: [1,2,3] }
               ]
            });

            $('select').on('change',function() {
              year    = $('#year-select').val().toLowerCase()
              month   = $('#month-select').val().toLowerCase()
              county  = $('#county-select').val();

              document.location = 'http://#{$settings[:host]}#{$settings[:basePath]}/report/#{group}/#{workflowIds}/'+year+'/'+month+'/'+county+'.html';
            });

            var
              layerControl,
              osm
            ;


            L.Icon.Default.imagePath = 'http://ntp.tangerinecentral.org/images/leaflet'

            window.map = new L.Map('map');

            osm = new L.TileLayer('http://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
              minZoom: 1,
              maxZoom: 12,
              attribution: 'Map data © OpenStreetMap contributors'
            });

            map.addLayer(osm);
            map.setView(new L.LatLng(0, 35), 6);

            layerControl = L.control.layers.provided([
              'OpenStreetMap.Mapnik',
              'Stamen.Watercolor'
            ]).addTo(map);

            window.markers = L.markerClusterGroup();
            
            // ready map data

            //var geojson = {
            //  'type'     : 'FeatureCollection',
            //  'features' : {} //{#geojson.to_json}
            //};



            window.geoJsonLayer = new L.GeoJSON.AJAX(mapDataURL['current'], {
              onEachFeature: function( feature, layer ) {
                var html = '';
            
                if (feature != null && feature.properties != null && feature.properties.length != null )
                {
                  feature.properties.forEach(function(cell){
                    html += '<b>' + cell.label + '</b> ' + cell.value + '<br>';
                  });
                }
                
                layer.bindPopup( html );
              }
            });

            window.geoJsonLayer.on('data:loaded', window.updateMap);

            //window.geoJsonLayer = L.geoJson( geojson, {
            //  onEachFeature: function( feature, layer ) {
            //    var html = '';
            //
            //    if (feature != null && feature.properties != null && feature.properties.length != null )
            //    {
            //      feature.properties.forEach(function(cell){
            //        html += '<b>' + cell.label + '</b> ' + cell.value + '<br>';
            //      });
            //    }
            //    
            //    layer.bindPopup( html );
            //  } // onEachFeature
            //}); // geoJson
   

          });

        </script>

      </head>

      <body>
        <h1><img style='vertical-align:middle;' src=\"#{$settings[:basePath]}/images/corner_logo.png\" title=\"Go to main screen.\"> TUSOME</h1>
  
        <label for='year-select'>Year</label>
        <select id='year-select'>
          <option #{"selected" if year == "2014"}>2014</option>
          <option #{"selected" if year == "2015"}>2015</option>
          <option #{"selected" if year == "2016"}>2016</option>
        </select>

        <label for='month-select'>Month</label>
        <select id='month-select'>
          <option value='1'  #{"selected" if month == "1"}>Jan</option>
          <option value='2'  #{"selected" if month == "2"}>Feb</option>
          <option value='3'  #{"selected" if month == "3"}>Mar</option>
          <option value='4'  #{"selected" if month == "4"}>Apr</option>
          <option value='5'  #{"selected" if month == "5"}>May</option>
          <option value='6'  #{"selected" if month == "6"}>Jun</option>
          <option value='7'  #{"selected" if month == "7"}>Jul</option>
          <option value='8'  #{"selected" if month == "8"}>Aug</option>
          <option value='9'  #{"selected" if month == "9"}>Sep</option>
          <option value='10' #{"selected" if month == "10"}>Oct</option>
          <option value='11' #{"selected" if month == "11"}>Nov</option>
          <option value='12' #{"selected" if month == "12"}>Dec</option>
        </select>

        <h2>Counties</h2>
        #{countyTableHtml}
        <br>
        <div id='charts'>
          <span id='charts-loading'>Loading charts...</span>
        </div>

        <br>

        <h2>
          #{titleize(currentCountyName)} County Report
          #{year} #{["","Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][month.to_i]}
        </h2>
        #{zoneTableHtml}
        
        
        <div id='map-loading'>Please wait. Data loading...</div>
        <div id='map' style='height: 400px'></div>

        <a href='#' onclick='swapMapData(); return false'>View All Data</a>
        
        </body>
      </html>
      "

    
    return html


  end # of report

end
