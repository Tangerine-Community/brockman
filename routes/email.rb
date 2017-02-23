# encoding: utf-8
require 'base64'
require 'date'
require_relative '../helpers/Couch'
require_relative '../utilities/countyTranslate'
require_relative '../utilities/zoneTranslate'
require_relative '../utilities/percentage'

class Brockman < Sinatra::Base
  
  get '/email/:email/:group/:year/:month/:county.?:format?' do | email, group, year, month, county, format |

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
    if result['visits']['dicece']['byCounty'][countyId].nil?
      result['visits']['dicece']['byCounty'].find { |countyId, county|
        currentCountyId   = countyId
        currentCounty     = county
        currentCountyName = county['name']
        true
      }
    else 
      currentCountyId   = countyId
      currentCounty     = result['visits']['dicece']['byCounty'][countyId]
      currentCountyName = currentCounty['name']
    end

    legendHtml = "
      <small>

      <ol>
        <li id='footer-note-1'><b>Numbers of classroom visits are</b> defined as TAYARI classroom observations that include all forms and all 3 pupils assessments, with at least 20 minutes duration, and took place between 7AM and 3.10PM of any calendar day during the selected month.</li>
        <li id='footer-note-2'><b>Targeted number of classroom visits</b> is equivalent to the number of class 1 teachers in each zone.</li>
      </ol>
      </small>
    "

    #retrieve a county list for the select and sort it
    countyList = []
    result['visits']['dicece']['byCounty'].map { |countyName, county| countyList.push countyName }
    countyList.sort!


    row = 0
    edCountyTableHtml = "
      <table>
        <thead>
          <tr>
            <th>County</th>
            <th class='custSort'>Number of classroom visits<a href='#footer-note-1'><sup>[1]</sup></a><br>
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

    emptyCounty = {
      "zones" => [] 
    }
    edZoneTableHtml = "
      <h2>Education Report for #{titleize(currentCountyName)} county</h2>
      <table>
        <thead>
          <tr>
            <th>Zone</th>
            <th class='custSort'>Number of classroom visits<a href='#footer-note-1'><sup>[1]</sup></a><br>
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

    healthCountyTableHtml = "
      <table>
        <thead>
          <tr>
            <th>County</th>
            <th class='custSort'>Number of classroom visits<a href='#footer-note-1'><sup>[1]</sup></a><br>
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
      </table>"

    healthZoneTableHtml = "
      <h2>Health Report for #{titleize(currentCountyName)} county</h2>
      <table>
        <thead>
          <tr>
            <th>Zone</th>
            <th class='custSort'>Number of classroom visits<a href='#footer-note-1'><sup>[1]</sup></a><br>
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
          "}.join }
        </tbody>
      </table>"

    if county.downcase != "all"
      edContentHtml = edZoneTableHtml
      healthContentHtml = healthZoneTableHtml
    else
      edContentHtml = edCountyTableHtml
      healthContentHtml = healthCountyTableHtml
    end

    html =  "
      <html>
        <head>
          <style>
            body{font-family:Helvetica;}
            table.dataTable{margin:0 auto;clear:both;width:100%}table.dataTable thead th{padding:3px 18px 3px 10px;border-bottom:1px solid #000;font-weight:700;cursor:pointer;*cursor:hand}table.dataTable tfoot th{padding:3px 18px 3px 10px;border-top:1px solid #000;font-weight:700}table.dataTable td{padding:3px 10px}table.dataTable td.center,table.dataTable td.dataTables_empty{text-align:center}table.dataTable tr.odd{background-color:#E2E4FF}table.dataTable tr.even{background-color:#fff}table.dataTable tr.odd td.sorting_1{background-color:#D3D6FF}table.dataTable tr.odd td.sorting_2{background-color:#DADCFF}table.dataTable tr.odd td.sorting_3{background-color:#E0E2FF}table.dataTable tr.even td.sorting_1{background-color:#EAEBFF}table.dataTable tr.even td.sorting_2{background-color:#F2F3FF}table.dataTable tr.even td.sorting_3{background-color:#F9F9FF}.dataTables_wrapper{position:relative;clear:both;*zoom:1}.dataTables_length{float:left}.dataTables_filter{float:right;text-align:right}.dataTables_info{clear:both;float:left}.dataTables_paginate{float:right;text-align:right}.paginate_disabled_next,.paginate_disabled_previous,.paginate_enabled_next,.paginate_enabled_previous{height:19px;float:left;cursor:pointer;*cursor:hand;color:#111!important}.paginate_disabled_next:hover,.paginate_disabled_previous:hover,.paginate_enabled_next:hover,.paginate_enabled_previous:hover{text-decoration:none!important}.paginate_disabled_next:active,.paginate_disabled_previous:active,.paginate_enabled_next:active,.paginate_enabled_previous:active{outline:0}.paginate_disabled_next,.paginate_disabled_previous{color:#666!important}.paginate_disabled_previous,.paginate_enabled_previous{padding-left:23px}.paginate_disabled_next,.paginate_enabled_next{padding-right:23px;margin-left:10px}.paginate_enabled_previous{background:url(../images/back_enabled.png) no-repeat top left}.paginate_enabled_previous:hover{background:url(../images/back_enabled_hover.png) no-repeat top left}.paginate_disabled_previous{background:url(../images/back_disabled.png) no-repeat top left}.paginate_enabled_next{background:url(../images/forward_enabled.png) no-repeat top right}.paginate_enabled_next:hover{background:url(../images/forward_enabled_hover.png) no-repeat top right}.paginate_disabled_next{background:url(../images/forward_disabled.png) no-repeat top right}.paging_full_numbers{height:22px;line-height:22px}.paging_full_numbers a:active{outline:0}.paging_full_numbers a:hover{text-decoration:none}.paging_full_numbers a.paginate_active,.paging_full_numbers a.paginate_button{border:1px solid #aaa;-webkit-border-radius:5px;-moz-border-radius:5px;border-radius:5px;padding:2px 5px;margin:0 3px;cursor:pointer;*cursor:hand;color:#333!important}.paging_full_numbers a.paginate_button{background-color:#ddd}.paging_full_numbers a.paginate_button:hover{background-color:#ccc;text-decoration:none!important}.paging_full_numbers a.paginate_active{background-color:#99B3FF}.dataTables_processing{position:absolute;top:50%;left:50%;width:250px;height:30px;margin-left:-125px;margin-top:-15px;padding:14px 0 2px;border:1px solid #ddd;text-align:center;color:#999;font-size:14px;background-color:#fff}.sorting{background:url(../images/sort_both.png) no-repeat center right}.sorting_asc{background:url(../images/sort_asc.png) no-repeat center right}.sorting_desc{background:url(../images/sort_desc.png) no-repeat center right}.sorting_asc_disabled{background:url(../images/sort_asc_disabled.png) no-repeat center right}.sorting_desc_disabled{background:url(../images/sort_desc_disabled.png) no-repeat center right}table.dataTable thead td:active,table.dataTable thead th:active{outline:0}.dataTables_scroll{clear:both}.dataTables_scrollBody{*margin-top:-1px;-webkit-overflow-scrolling:touch}
          </style>

        </head>

        <body>
          <h1><img style='vertical-align:middle;' src=\"http://databases.tangerinecentral.org/tangerine/_design/ojai/images/corner_logo.png\" title=\"Go to main screen.\"> TAYARI</h1>

          #{edContentHtml}
          <br/>
          #{healthContentHtml}
          <p><a href='http://tools.tayari-tangerine.tangerinecentral.org/_csv/report/#{group}/#{year}/#{month}/#{currentCountyId}.html'>View map and details</a></p>
        </body>
      </html>

      "

    premailer = Premailer.new(html, 
      :with_html_string => true, 
      :warn_level => Premailer::Warnings::SAFE
    )
    mailHtml = premailer.to_inline_css

    if county.downcase != "all"
      emailSubject = "Report for #{currentCountyName} County"
    else
      emailSubject = "County Report"
    end

    if email
      
      
      email.force_encoding("UTF-8")
      emailSubject.force_encoding("UTF-8")
      mailHtml.force_encoding("UTF-8")
      File.open('special.log', 'w') { |file| file.write("#{email.encoding}\n#{emailSubject.encoding}\n#{mailHtml.encoding}") }
      mail = Mail.deliver do
        to      email
        from    'Tayari <no-reply@tools.tayari-tangerine.tangerinecentral.org>'
        subject emailSubject

        html_part do
          content_type 'text/html; charset=UTF-8'
          body mailHtml
        end
      end

    end

    if format == "json"
      return { 'sent' => true, 'mail' => mail.to_s }.to_json
    else
      mailHtml
    end

  end

end
