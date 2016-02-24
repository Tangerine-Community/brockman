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

  get '/report/:group/:year/:month/:district?.:format?' do | group, year, month, district, format |

    format = "html" unless format == "json"
    
    districtId = district || ""

    requestId = SecureRandom.base64

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
      result = couch.getRequest({ :doc => "report-aggregate-year#{year}month#{month}", :parseJson => true })
    rescue => e
      # the doc doesn't already exist
      puts e
      return invalidReport()
    end

    
    currentDistrictId       = nil
    currentDistrict         = nil
    currentDistrictName     = nil

   
    #ensure that the county in the URL is valid - if not, select the first
    if result['visits']['byDistrict'][districtId].nil?
      result['visits']['byDistrict'].find { |districtId, district|
        currentDistrictId   = districtId
        currentDistrict     = district
        currentDistrictName = district['name']
        true
      }
    else 
      currentDistrictId   = districtId
      currentDistrict     = result['visits']['byDistrict'][districtId]
      currentDistrictName = currentDistrict['name']
    end

    

    row = 0
    districtTableHtml = "
      <table>
        <thead>
          <tr>
            <th>District</th>
            <th class='custSort'>Number of Schools Visited</th>
            <th class='custSort'>Number of Observations Completed</th>
          </tr>
        </thead>
        <tbody>
          #{ result['visits']['byDistrict'].map{ | districtId, district |

            districtName      = district['name']
            visits            = district['visits']
            observations      = district['observations']
            sampleTotal       = 0

            "
              <tr>
                <td>#{titleize(districtName)}</td>
                <td>#{visits} Schools</td>
                <td>#{observations} Observations</td>
              </tr>
            "}.join }
            <tr>
              <td>All</td>
              <td>#{result['visits']['national']['visits']} Schools</td>
              <td>#{result['visits']['national']['observations']} Observations</td>
            </tr>
        </tbody>
      </table>
    "

    zoneTableHtml = "
      <label for='district-select'>District</label>
        <select id='district-select'>
          #{
            orderedDistricts = result['visits']['byDistrict'].sort_by{ |districtId, district| district['name'] }
            orderedDistricts.map{ | districtId, district |
              "<option value='#{districtId}' #{"selected" if districtId == currentDistrictId}>#{titleize(district['name'])}</option>"
            }.join("")
          }
        </select>
      <table>
        <thead>
          <tr>
            <th>Zone</th>
            <th class='custSort'>Number of Schools Visited</th>
            <th class='custSort'>Number of Observations Completed</th>
          </tr>
        </thead>
        <tbody>
          #{result['visits']['byDistrict'][currentDistrictId]['zones'].map{ | zoneId, zone |

            row += 1

            zoneName      = zone['name']
            visits        = zone['visits']
            observations  = zone['observations']
            

          "
            <tr> 
              <td>#{zoneName}</td>
              <td>#{visits} Schools</td>
              <td>#{observations} Observations</td>
            </tr>
          "}.join }
        </tbody>
      </table>

    "


    html =  "
    <html>
      <head>
        <link rel='stylesheet' type='text/css' href='http://ajax.aspnetcdn.com/ajax/jquery.dataTables/1.9.4/css/jquery.dataTables.css'>
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

        <script src='/javascript/base64.js'></script>
        <script src='http://code.jquery.com/jquery-1.11.0.min.js'></script>
        <script src='http://ajax.aspnetcdn.com/ajax/jquery.dataTables/1.9.4/jquery.dataTables.min.js'></script>
        

        <script>


          $(document).ready( function() {

            
            $('table').dataTable( { 
              iDisplayLength :-1, 
              sDom : 't',
              aoColumnDefs: [
                 { sType: 'num-html', aTargets: [1,2] }
               ]
            });

            $('select').on('change',function() {
              year    = $('#year-select').val().toLowerCase()
              month   = $('#month-select').val().toLowerCase()
              district  = $('#district-select').val();

              document.location = 'http://#{$settings[:host]}#{$settings[:basePath]}/report/#{group}/'+year+'/'+month+'/'+district+'.html';
            });
          });

        </script>

      </head>

      <body>
        <h1><img style='vertical-align:middle;' src=\"#{$settings[:basePath]}/images/corner_logo.png\" title=\"Go to main screen.\"> Malawi Tutor</h1>
  
        <label for='year-select'>Year</label>
        <select id='year-select'>
          <option #{"selected" if year == "2016"}>2016</option>
          <option #{"selected" if year == "2017"}>2017</option>
          <option #{"selected" if year == "2018"}>2018</option>
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

        <h2>Districts</h2>
        #{districtTableHtml}
        

        <h2>
          #{titleize(currentDistrictName)} District Report
          #{year} #{["","Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][month.to_i]}
        </h2>
        #{zoneTableHtml}
        
        </body>
      </html>
      "

    
    return html


  end # of report

end
