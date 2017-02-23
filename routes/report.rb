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

  get '/report/:group/:year/:month/:county.:format?' do | group, year, month, county, format |

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

    
    currentCountyId       = nil
    currentCounty         = nil
    currentCountyName     = nil

   
    #ensure that the county in the URL is valid - if not, select the first
    if result['visits']['cha']['byCounty'][countyId].nil?
      result['visits']['cha']['byCounty'].find { |countyId, county|
        currentCountyId   = countyId
        currentCounty     = county
        currentCountyName = county['name']
        true
      }
    else 
      currentCountyId   = countyId
      currentCounty     = result['visits']['cha']['byCounty'][countyId]
      currentCountyName = currentCounty['name']
    end

    #retrieve a county list for the select and sort it

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
      var datasetObservationsEdCounty = Array();
      var datasetObservationsEdZone = Array();

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
          for(var county in el.data.visits.dicece.byCounty)
          {

            var tmpCounty = titleize(safeRead(el.data.visits.dicece.byCounty[county], 'name'));
            var tmp = {
              County   : tmpCounty,
              MonthInt : el.month,
              Year     : el.year,
              Month    : months[el.month]
            };
            
            var tmpVisit = {};
            var countyVisits = safeRead(el.data.visits.dicece.byCounty[county], 'visits');
            var countyQuota = safeRead(el.data.visits.dicece.byCounty[county],'quota');

            if (countyVisits == 0 || countyQuota == 0){
              tmpVisit['Visit Attainment'] = 0;
            } else {
              tmpVisit['Visit Attainment'] = countyVisits / countyQuota * 100;
            }

            datasetObservationsEdCounty.push($.extend({}, tmp, tmpVisit));          
            
            //zone data
            var countyId  = '#{countyId}';
            for(var zone in el.data.visits.dicece.byCounty[county].zones)
            {
              var tmpZone = titleize(safeRead(el.data.visits.dicece.byCounty[county].zones[zone], 'name'));
              var tmpZoneData = {
                Zone   : tmpZone,
                MonthInt : el.month,
                Year     : el.year,
                Month    : months[el.month]
              };

              var tmpZoneVisit = {};
              var zoneVisits = safeRead(el.data.visits.dicece.byCounty[county].zones[zone], 'visits');
              var zoneQuota = safeRead(el.data.visits.dicece.byCounty[county].zones[zone],'quota');

              if (zoneVisits == 0 || zoneQuota == 0){
              tmpZoneVisit['Visit Attainment'] = 0;
              } else {
                tmpZoneVisit['Visit Attainment'] = zoneVisits / zoneQuota * 100;
              }
              
              datasetObservationsEdZone.push($.extend({}, tmpZoneData, tmpZoneVisit));
            }

          }
        })
        
        // Build the charts. 
        addChart(datasetObservationsEdCounty, 'Visit Attainment', 'Classroom Observations (County)','Percentage');
        addZoneChart(datasetObservationsEdZone, 'Visit Attainment', 'Classroom Observations (Zone)','Percentage');
        $('#charts-loading').remove()

      }     

      function addZoneChart(dataset, variable, title, xaxis)
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
          var y = chart.addCategoryAxis('y', ['Zone','Month']);
          y.addOrderRule('Zone');
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
        chartObject.yAxis = 'Zone';
        chartObject.xAxis = xaxis;
        
        // show hover tooltips
        chartObject.showHover = true;
        buildChart(chartObject);
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

     healthChartJs = "
      function titleize(str){
        return str.replace(/\\w\\S*/g, function(txt) {
          return txt.charAt(0).toUpperCase() + txt.substr(1).toLowerCase();
        }).replace(/apbet/gi, 'APBET');
      }

      var base = 'http://#{$settings[:host]}#{$settings[:basePath]}/'; // will need to update this for live development

      // called on document ready
      var initHealthChart = function()
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
        q.await(buildHealthReportCharts);
      }

      var datasetScores = Array()
      var datasetObservationsHealthCounty = Array();
      var datasetObservationsHealthZone = Array();

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
      
      function buildHealthReportCharts()
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
          for(var county in el.data.visits.cha.byCounty)
          {

            var tmpCounty = titleize(safeRead(el.data.visits.cha.byCounty[county], 'name'));
            var tmp = {
              County   : tmpCounty,
              MonthInt : el.month,
              Year     : el.year,
              Month    : months[el.month]
            };
            
            var tmpVisit = {};
            var countyVisits = safeRead(el.data.visits.cha.byCounty[county], 'visits');
            var countyQuota = safeRead(el.data.visits.cha.byCounty[county],'quota');

            if (countyVisits == 0 || countyQuota == 0){
              //tmpVisit['Visit Attainment'] = 0;
            } else {
              tmpVisit['Visit Attainment'] = countyVisits / countyQuota * 100;
              datasetObservationsHealthCounty.push($.extend({}, tmp, tmpVisit));  
            }

                    
            
            //zone data
            var countyId  = '#{countyId}';
            for(var zone in el.data.visits.cha.byCounty[county].zones)
            {
              var tmpZone = titleize(safeRead(el.data.visits.cha.byCounty[county].zones[zone], 'name'));
              var tmpZoneData = {
                Zone   : tmpZone,
                MonthInt : el.month,
                Year     : el.year,
                Month    : months[el.month]
              };

              var tmpZoneVisit = {};
              var zoneVisits = safeRead(el.data.visits.cha.byCounty[county].zones[zone], 'visits');
              var zoneQuota = safeRead(el.data.visits.cha.byCounty[county].zones[zone],'quota');

              if (zoneVisits == 0 || zoneQuota == 0){
              //tmpZoneVisit['Visit Attainment'] = 0;
              } else {
                tmpZoneVisit['Visit Attainment'] = zoneVisits / zoneQuota * 100;
                datasetObservationsHealthZone.push($.extend({}, tmpZoneData, tmpZoneVisit));
              }
              
              
            }

          }
        })
        
        // Build the charts. 
        addHealthChart(datasetObservationsHealthCounty, 'Visit Attainment', 'Classroom Observations (County)','Percentage');
        addHealthZoneChart(datasetObservationsHealthZone, 'Visit Attainment', 'Classroom Observations (Zone)','Percentage');
        $('#health-charts-loading').remove()

      }     

      function addHealthZoneChart(dataset, variable, title, xaxis)
      {
        // create the element that the chart lives in
        var domid = (new Date()).getTime();
        $('#health-charts').append('<div class=\"chart\"><h2 style=\"text-align:center;\">'+title+'</h2><div id=\"chartContainer'+domid+'\" /></div>');

        // start building chart object to pass to render function
        chartObject = new Object();
        chartObject.container = '#chartContainer'+domid;
        chartObject.height = 650;
        chartObject.width = 450;
        chartObject.data =  dataset;
        
        chartObject.plot = function(chart){

          // setup x, y and series
          var y = chart.addCategoryAxis('y', ['Zone','Month']);
          y.addOrderRule('Zone');
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
        chartObject.yAxis = 'Zone';
        chartObject.xAxis = xaxis;
        
        // show hover tooltips
        chartObject.showHover = true;
        buildChart(chartObject);
      }

      function addHealthChart(dataset, variable, title, xaxis)
      {
        // create the element that the chart lives in
        var domid = (new Date()).getTime();
        $('#health-charts').append('<div class=\"chart\"><h2 style=\"text-align:center;\">'+title+'</h2><div id=\"chartContainer'+domid+'\" /></div>');

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
        buildHealthChart(chartObject);
      }
      
      function buildHealthChart(chart)
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
    #****************************** Education Report Components *************************
    row = 0
    edCountyTableHtml = "
      <table class='education-table'>
        <thead>
          <tr>
            <th>County</th>
            <th class='custSort' align='left'>Number of classroom visits<a href='#footer-note-1'><sup>[1]</sup></a><br>
            <small>( Percentage of Target Visits)</small></th>
          </tr>
        </thead>
        <tbody>
          #{ result['visits']['dicece']['byCounty'].map{ | countyId, county |

            countyName      = county['name']
            visits          = county['visits']
            quota           = county['quota']

            "
              <tr>
                <td>#{titleize(countyName)}</td>
                <td>#{visits} ( #{percentage( quota, visits )}% )</td>
              </tr>
            "}.join }
            <tr>
              <td>All</td>
              <td>#{result['visits']['dicece']['national']['visits']} ( #{percentage( result['visits']['dicece']['national']['quota'], result['visits']['dicece']['national']['visits'] )}% )</td>
              
            </tr>
        </tbody>
      </table>
    "

    edZoneTableHtml = "
      <label for='ed-county-select'>County</label>
        <select id='ed-county-select'>
          #{
            orderedCounties = result['visits']['dicece']['byCounty'].sort_by{ |countyId, county| county['name'] }
            orderedCounties.map{ | countyId, county |
              "<option value='#{countyId}' #{"selected" if countyId == currentCountyId}>#{titleize(county['name'])}</option>"
            }.join("")
          }
        </select>
      <table class='education-table'>
        <thead>
          <tr>
            <th>Zone</th>
            <th class='custSort' align='left'>Number of classroom visits<a href='#footer-note-1'><sup>[1]</sup></a><br>
            <small>( Percentage of Target Visits)</small></th>
          </tr>
        </thead>
        <tbody>
          #{result['visits']['dicece']['byCounty'][currentCountyId]['zones'].map{ | zoneId, zone |

            row += 1

            zoneName = zone['name']
            visits = zone['visits']
            quota = zone['quota']
          "
            <tr> 
              <td>#{zoneName}</td>
              <td>#{visits} ( #{percentage( quota, visits )}% )</td>
              
            </tr>
          "}.join }
        </tbody>
      </table>
     

    "

    #****************************** Health Report Components *************************
    row = 0
    healthCountyTableHtml = "
      <table class='health-table'>
        <thead>
          <tr>
            <th>County</th>
            <th class='custSort' align='left'>Number of classroom visits<a href='#footer-note-1'><sup>[1]</sup></a><br>
            <small>( Percentage of Target Visits)</small></th>
            
          </tr>
        </thead>
        <tbody>
          #{ result['visits']['cha']['byCounty'].map{ | countyId, county |

            countyName      = county['name']
            visits          = county['visits']
            quota           = county['quota']
            sampleTotal     = 0

            "
              <tr>
                <td>#{titleize(countyName)}</td>
                <td>#{visits} ( #{percentage( quota, visits )}% )</td>
                
              </tr>
            "}.join }
            <tr>
              <td>All</td>
              <td>#{result['visits']['cha']['national']['visits']} ( #{percentage( result['visits']['cha']['national']['quota'], result['visits']['cha']['national']['visits'] )}% )</td>
            </tr>
        </tbody>
      </table>
    "

    healthZoneTableHtml = "
      <label for='health-county-select'>County</label>
        <select id='health-county-select'>
          #{
            orderedCounties = result['visits']['cha']['byCounty'].sort_by{ |countyId, county| county['name'] }
            orderedCounties.map{ | countyId, county |
              "<option value='#{countyId}' #{"selected" if countyId == currentCountyId}>#{titleize(county['name'])}</option>"
            }.join("")
          }
        </select>
      <table class='health-table'>
        <thead>
          <tr>
            <th>Zone</th>
            <th class='custSort' align='left'>Number of classroom visits<a href='#footer-note-1'><sup>[1]</sup></a><br>
            <small>( Percentage of Target Visits)</small></th>
          </tr>
        </thead>
        <tbody>
          #{result['visits']['cha']['byCounty'][currentCountyId]['zones'].map{ | zoneId, zone |

            row += 1

            zoneName = zone['name']
            visits = zone['visits']
            quota = zone['quota']
      
          "
            <tr> 
              <td>#{zoneName}</td>
              <td>#{visits} ( #{percentage( quota, visits )}% )</td>
              
            </tr>
          " 
         
          }.join }
        </tbody>
      </table>

    "
    

    #************************ Tab Definition ************************
    edTabContent = "
      
      <h2>Education Report (#{year} #{["","Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][month.to_i]})</h2>
      <hr>
      <h2>Counties</h2>
      #{edCountyTableHtml}
      <br>
      <div id='charts'>
        <span id='charts-loading'>Loading charts...</span>
      </div>

      <br>

      <h2>
        #{titleize(currentCountyName)} County Report
      </h2>
      #{edZoneTableHtml}
      
      
      <div id='ed-map-loading'>Please wait. Data loading...</div>
      <div id='ed-map' style='height: 400px'></div>
      <br>
      <a id='ed-view-all-btn' class='btn' href='#'>View All County Data</a>
    "

    healthTabContent = "
      <h2>Health Report (#{year} #{["","Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][month.to_i]})</h2>
      <hr>
      <h2>Counties</h2>
      #{healthCountyTableHtml}
      <br>
      <div id='health-charts'>
        <span id='health-charts-loading'>Loading charts...</span>
      </div>
      <br>
      <h2>
        #{titleize(currentCountyName)} County Report
      </h2>
      #{healthZoneTableHtml}

      <br>
      <div id='health-map-loading'>Please wait. Data loading...</div>
      <div id='health-map' style='height: 400px'></div>
      <br>
      <a id='health-view-all-btn' class='btn' href='#'>View All County Data</a>
    "

    
    html =  "
    <html>
      <head>
        <link rel='stylesheet' type='text/css' href='#{$settings[:basePath]}/css/report.css'>
        <link rel='stylesheet' type='text/css' href='http://ajax.aspnetcdn.com/ajax/jquery.dataTables/1.9.4/css/jquery.dataTables.css'>
        <link rel='stylesheet' type='text/css' href='http://cdn.leafletjs.com/leaflet-0.7.2/leaflet.css'>
        <link rel='stylesheet' type='text/css' href='http://cdnjs.cloudflare.com/ajax/libs/leaflet.markercluster/0.4.0/MarkerCluster.css'>
        <link rel='stylesheet' type='text/css' href='http://cdnjs.cloudflare.com/ajax/libs/leaflet.markercluster/0.4.0/MarkerCluster.Default.css'>
        

        <script src='http://cdnjs.cloudflare.com/ajax/libs/moment.js/2.9.0/moment.min.js'></script>

        <script src='#{$settings[:basePath]}/javascript/base64.js'></script>
        <script src='http://code.jquery.com/jquery-1.11.0.min.js'></script>
        <script src='http://ajax.aspnetcdn.com/ajax/jquery.dataTables/1.9.4/jquery.dataTables.min.js'></script>
        <script src='http://cdn.leafletjs.com/leaflet-0.7.2/leaflet.js'></script>
        <script src='http://cdnjs.cloudflare.com/ajax/libs/leaflet.markercluster/0.4.0/leaflet.markercluster.js'></script>
        <script src='#{$settings[:basePath]}/javascript/leaflet/leaflet-providers.js'></script>
        <script src='#{$settings[:basePath]}/javascript/leaflet/leaflet.ajax.min.js'></script>

        <script src='http://d3js.org/d3.v3.min.js'></script>
        <script src='http://dimplejs.org/dist/dimple.v2.0.0.min.js'></script>
        <script src='http://d3js.org/queue.v1.min.js'></script>

        <script>

          #{chartJs}
          #{healthChartJs}

          updateMap = function() {

            if ( window.markers == null || window.map == null || window.geoJsonLayer == null ) { return; }

            window.markers.addLayer(window.geoJsonLayer);
            window.map.addLayer(window.markers);
            $('#map-loading').hide();

          };

          var mapDataURL = new Array();
          mapDataURL['current'] = base+'reportData/#{group}/report-aggregate-geo-year#{year.to_i}month#{month.to_i}-#{currentCountyId}.geojson';
          mapDataURL['all'] = new Array();

          mapDataURL['all']
          #{
            result['visits']['dicece']['byCounty'].map{ | countyId, county |
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
          
          L.Icon.Default.imagePath = 'http://ntp.tangerinecentral.org/images/leaflet'
          var pageMaps = {}
          var mapControls = {
            ed: {
              osm: new L.TileLayer('http://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
                minZom: 1,
                maxZoom: 12,
                attribution: 'Map data © OpenStreetMap contributors'
              }),
              layerControl: L.control.layers.provided(['OpenStreetMap.Mapnik','Stamen.Watercolor']),
              markers: L.markerClusterGroup(),
              layerGeoJsonFilter: function(feature, layer){
                return (feature.role === 'dicece');
              }
            },
            health: {
              osm: new L.TileLayer('http://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
                minZom: 1,
                maxZoom: 12,
                attribution: 'Map data © OpenStreetMap contributors'
              }),
              layerControl: L.control.layers.provided(['OpenStreetMap.Mapnik','Stamen.Watercolor']),
              markers: L.markerClusterGroup(),
              layerGeoJsonFilter: function(feature, layer){
                return (feature.role === 'cha');
              }
            }
          };


          var layerOnEachFeature = function(feature, layer){
            var html = '';
            if (feature != null && feature.properties != null && feature.properties.length != null ){
              feature.properties.forEach(function(cell){
                if(cell.label != 'role'){
                  html += '<b>' + cell.label + '</b> ' + cell.value + '<br>';
                }
              });
            }
            
            layer.bindPopup( html );
          };

          $(document).ready( function() {
            //if there is a hash in the URL, change the tab to match it
            var hash = location.hash.replace(/^#/, '');
            forceTabSelect(hash);

            initChart()
            initHealthChart()

            /***********
            **
            **   Init Custom Data Tables
            **
            ************/
            //init display for the TAC Tutor Tab
            $('table.education-table').dataTable( { 
              iDisplayLength :-1, 
              sDom : 't'
            });

            //init display for the SCDE Tab
            $('table.health-table').dataTable( { 
              iDisplayLength :-1, 
              sDom : 't'
            });

              
            /***********
            **
            **   Init Select Handlers
            **
            ************/
            var currCounty = '#{countyId}';
            $('#year-select,#month-select').on('change',function() {
              reloadReport();
            });

            $('#ed-county-select').on('change',function() {
              currCounty = $('#ed-county-select').val()
              reloadReport();
            });

            $('#health-county-select').on('change',function() {
              currCounty = $('#health-county-select').val()
              reloadReport();
            });

            function reloadReport(){
              year    = $('#year-select').val().toLowerCase()
              month   = $('#month-select').val().toLowerCase()

              document.location = 'http://#{$settings[:host]}#{$settings[:basePath]}/report/#{group}/'+year+'/'+month+'/'+currCounty+'.html'+location.hash;
            }

            
            /***********
            **
            **   Init Leaflet Maps
            **
            ************/

            
            window.markers = L.markerClusterGroup();
            
            pageMaps.ed = new L.Map('ed-map');
            pageMaps.health  = new L.Map('health-map');
            
            //----------- Education MAP CONFIG -------------------------
            pageMaps.ed.addLayer(mapControls.ed.osm);
            pageMaps.ed.setView(new L.LatLng(0, 35), 6);
            mapControls.ed.layerControl.addTo(pageMaps.ed);
            mapControls.ed.geoJsonLayer = new L.GeoJSON.AJAX(mapDataURL['current'], {
              onEachFeature: layerOnEachFeature,
              filter: mapControls.ed.layerGeoJsonFilter
            });
            mapControls.ed.geoJsonLayer.on('data:loaded', function(){
              if ( mapControls.ed.markers == null || pageMaps.ed == null || mapControls.ed.geoJsonLayer == null ) { return; }
              mapControls.ed.markers.addLayer(mapControls.ed.geoJsonLayer);
              pageMaps.ed.addLayer(mapControls.ed.markers);
              $('#ed-map-loading').hide();
            });
            $('#ed-view-all-btn').on('click', function(event){
              mapControls.ed.geoJsonLayer.refresh(mapDataURL['all']);
              $('#ed-map-loading').show();
              $('#ed-view-all-btn').hide();
            });
            
            //----------- Health MAP CONFIG -------------------------
            pageMaps.health.addLayer(mapControls.health.osm);
            pageMaps.health.setView(new L.LatLng(0, 35), 6);
            mapControls.health.layerControl.addTo(pageMaps.health);
            mapControls.health.geoJsonLayer = new L.GeoJSON.AJAX(mapDataURL['current'], {
              onEachFeature: layerOnEachFeature,
              filter: mapControls.health.layerGeoJsonFilter
            });
            mapControls.health.geoJsonLayer.on('data:loaded', function(){
              if ( mapControls.health.markers == null || pageMaps.health == null || mapControls.health.geoJsonLayer == null ) { return; }
              mapControls.health.markers.addLayer(mapControls.health.geoJsonLayer);
              pageMaps.health.addLayer(mapControls.health.markers);
              $('#health-map-loading').hide();
            });
            $('#health-view-all-btn').on('click', function(event){
              mapControls.health.geoJsonLayer.refresh(mapDataURL['all']);
              $('#health-map-loading').show();
              $('#health-view-all-btn').hide();
            });
          });
        </script>

      </head>

      <body>
        <h1><img style='vertical-align:middle;' src=\"#{$settings[:basePath]}/images/corner_logo.png\" title=\"Go to main screen.\"> TAYARI</h1>
  
        <label for='year-select'>Year</label>
        <select id='year-select'>
          <option #{"selected" if year == "2014"}>2014</option>
          <option #{"selected" if year == "2015"}>2015</option>
          <option #{"selected" if year == "2016"}>2016</option>
          <option #{"selected" if year == "2017"}>2017</option>
        </select>

        <label for='month-select'>Month</label>
        <select id='month-select'>
          <option value='1'  #{"selected" if month == "1"}>Jan</option>
          <option value='2'  #{"selected" if month == "2"}>Feb</option>
          <option value='3'  #{"selected" if month == "3"}>Mar</option>
          <!--<option value='4'  #{"selected" if month == "4"}>Apr</option>-->
          <option value='5'  #{"selected" if month == "5"}>May</option>
          <option value='6'  #{"selected" if month == "6"}>Jun</option>
          <option value='7'  #{"selected" if month == "7"}>Jul</option>
          <!--<option value='8'  #{"selected" if month == "8"}>Aug</option>-->
          <option value='9'  #{"selected" if month == "9"}>Sep</option>
          <option value='10' #{"selected" if month == "10"}>Oct</option>
          <option value='11' #{"selected" if month == "11"}>Nov</option>
          <!--<option value='12' #{"selected" if month == "12"}>Dec</option>-->
        </select>
        
        <div class='tab_container'>
          <div id='tab-ed' class='tab first selected' data-id='ed'>Education</div>
          <div id='tab-health' class='tab' data-id='health'>Health</div>
          <section id='panel-ed' class='tab-panel' style=''>
            #{edTabContent}
          </section>
          <section id='panel-health' class='tab-panel' style='display:none;'>
            #{healthTabContent}
          </section>
        </div>
        
        
        <script>
          /*****
          **  Setup and Manage Tabs
          ******/
          $('.tab').on('click', handleTabClick);

          function handleTabClick(event){
            var tabId = $(event.target).attr('data-id');
            displayTab(tabId);
            
            event.preventDefault();
            window.location.hash = '#'+tabId;
          }

          function forceTabSelect(tabId){
            if( $('#tab-'+tabId).length ){
              displayTab(tabId)
            } else {
              displayTab('ed')
            }
          }

          function displayTab(tabId){
            $('.tab').removeClass('selected');
            $('.tab-panel').hide();

            $('#tab-'+tabId).addClass('selected');
            $('#panel-'+tabId).show();
            
            if(typeof pageMaps[tabId] !== 'undefined'){
              pageMaps[tabId].invalidateSize();
            }
            
          }
        </script>
      </body>
    </html>
    "

    
    return html


  end # of report

end
