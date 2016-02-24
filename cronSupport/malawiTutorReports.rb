# encoding: utf-8

#require 'rest-client'
#require 'json'
#require_relative "Stash"
require_relative "../utilities/TimeDifference"

class MalawiTutorReports

  def initialize( options = {} )

    @couch          = options[:couch]
    @timezone       = options[:timezone]
    puts "MalawiTutorReports: Init Complete"

    @locationList = nil
    @tripsSkipped = 0

  end # of initialize

  # Process locations
  def processLocations(templates)
    
    # TODO: Resolve this hard-coded Subtest ID
    @locationList = @couch.getRequest({ 
      :doc => "0fe7145e-78c4-81d2-5575-d9fdf038c408", 
      :parseJson => true 
    })
    @locations = @locationList["locations"] || []

    templates['locationBySchool']                              ||= {}

    # define scope for result
    templates                                                  ||= {}
    templates['result']['visits']                              ||= {}
    templates['result']['visits']['byDistrict']                ||= {}
    templates['result']['visits']['national']                  ||= {}
    templates['result']['visits']['national']['visits']        ||= 0
    templates['result']['visits']['national']['observations']  ||= 0


    templates['result']['users']           ||= {}  #stores list of all users and zone associations
    templates['result']['users']['all']    ||= {}  #stores list of all users


    # define scope or the geoJSON files
    templates['geoJSON']                 ||= {}
    templates['geoJSON']['byDistrict']   ||= {}

    #
    # Retrieve Shool Locations and Quotas
    #

    districtsGrp = @locations.group_by { |loc| Base64.urlsafe_encode64(loc[0]) }
    # puts districts #REMOVE

    # Init the data structures based on the school list 
    districtsGrp.map { | districtId, districts |
      templates['result']['visits']['byDistrict'][districtId]                  ||= {}

      districts.each { |district| 
        templates['result']['visits']['byDistrict'][districtId]['name']          ||= district[0]
        templates['result']['visits']['byDistrict'][districtId]['zones']         ||= {}
        templates['result']['visits']['byDistrict'][districtId]['visits']        ||= 0
        templates['result']['visits']['byDistrict'][districtId]['observations']  ||= 0
      }

      zoneGrp = districts.group_by { |loc| Base64.urlsafe_encode64(loc[1]) }
      zoneGrp.map { |zoneId, zones| 
        templates['result']['visits']['byDistrict'][districtId]['zones'][zoneId]  ||= {}

        zones.each { |zone| 
          templates['result']['visits']['byDistrict'][districtId]['zones'][zoneId]['name']           ||= zone[1]
          templates['result']['visits']['byDistrict'][districtId]['zones'][zoneId]['schools']        ||= {}
          templates['result']['visits']['byDistrict'][districtId]['zones'][zoneId]['visits']         ||= 0
          templates['result']['visits']['byDistrict'][districtId]['zones'][zoneId]['observations']   ||= 0

          schoolId = Base64.urlsafe_encode64(zone[2])
          templates['result']['visits']['byDistrict'][districtId]['zones'][zoneId]['schools'][schoolId]                   ||= {}
          templates['result']['visits']['byDistrict'][districtId]['zones'][zoneId]['schools'][schoolId]['name']             = zone[2]
          templates['result']['visits']['byDistrict'][districtId]['zones'][zoneId]['schools'][schoolId]['emisCode']         = zone[3]
          templates['result']['visits']['byDistrict'][districtId]['zones'][zoneId]['schools'][schoolId]['visits']           = 0
          templates['result']['visits']['byDistrict'][districtId]['zones'][zoneId]['schools'][schoolId]['observations']     = 0

          templates['locationBySchool'][schoolId]                  ||= {}
          templates['locationBySchool'][schoolId]['districtId']      = districtId
          templates['locationBySchool'][schoolId]['zoneId']          = zoneId
        }
      }

      #init geoJSON Containers
      templates['geoJSON']['byDistrict'][districtId]         ||= {}
      templates['geoJSON']['byDistrict'][districtId]['data'] ||= []
    }
    
    return templates
  end # of processLocations

  # Process users
  def processUsers(templates)
    
    userDocs = @couch.getRequest({
      :doc => "_all_docs",
      :params => { 
        "startkey" => "user-".to_json,
        "include_docs" => true
      },
      :parseJson => true
    })

    puts "    #{userDocs['rows'].size} Total Users"
    #associate users with their county and zone for future processing
    userDocs['rows'].map{ | user | 

      username                                          = user['doc']['name'].downcase
      templates['users']['all']                       ||= {}

      templates['users']['all'][username]                            ||= {}
      templates['users']['all'][username]['data']                      = user['doc']

      templates['users']['all'][username]['visits']                  ||= {}      # container for target zone visits
      templates['users']['all'][username]['observations']            ||= 0
      templates['users']['all'][username]['schoolsVisited']          ||= 0
      templates['users']['all'][username]['observationData']         ||= []
    }

    return templates
  end # of processUsers

#
#
#  Process each individual trip 
#
#
  # Process an individual trip
  def processTrip(trip, monthData, templates, workflows)
    #puts "Processing Trip"  
    
    #puts trip if @tripsSkipped <= 1

    workflowId = trip['value']['workflowId'] || trip['id']
    username   = trip['value']['user']       || ""

    # handle case of irrelevant workflow 
    return err(true, "Incomplete or Invalid Workflow: #{workflowId}") if not workflows[workflowId]
    return err(true, "Workflow does not get pre-processed: #{workflowId}") if not workflows[workflowId]['reporting']['preProcess']

    # validate user 
    return err(true, "User does not exist: #{username}") if not monthData['users']['all'][username]
    
    # validate against the workflow constraints
    validated = validateTrip(trip, workflows[workflowId])
    return err(true, "Trip did not validate against workflow constraints") if not validated

    # verify school
    return err(true, "School was not found in trip") if trip['value']['school'].nil?
          
    schoolId      = Base64.urlsafe_encode64(trip['value']['school'])
    return err(true, "School was not found in database") if templates['locationBySchool'][schoolId].nil?

    zoneId        = templates['locationBySchool'][schoolId]['zoneId']        || ""
    districtId    = templates['locationBySchool'][schoolId]['districtId']    || ""
    username      = trip['value']['user'].downcase
    
    if !@timezone.nil?
      tripDate = Time.at(trip['value']['minTime'].to_i / 1000).getlocal(@timezone)
    else 
      tripDate = Time.at(trip['value']['minTime'].to_i / 1000)
    end

    monthData['users']['all'][username]['observationData'].push({"dayOfMonth"=>tripDate.day , "schoolId"=>schoolId})
    monthData['users']['all'][username]['observations'] += 1

      
    #
    # Process geoJSON data for mapping
    #
    if !trip['value']['gpsData'].nil?
      point = trip['value']['gpsData']

      point['properties'] = [
        { 'label' => 'Date',            'value' => tripDate },
        { 'label' => 'District',        'value' => titleize(monthData['result']['visits']['byDistrict'][districtId]['name'].downcase) },
        { 'label' => 'Zone',            'value' => titleize(monthData['result']['visits']['byDistrict'][districtId]['zones'][zoneId]['name'].downcase) },
        { 'label' => 'School',          'value' => titleize(monthData['result']['visits']['byDistrict'][districtId]['zones'][zoneId]['schools'][schoolId]['name'].downcase) },
        { 'label' => 'PEA',             'value' => titleize(trip['value']['user'].downcase) }
      ]

      monthData['geoJSON']['byDistrict'][districtId]['data'].push point
    end
  end # of processTrip

#
#
#  Post-Process the trip data
#
#
  def postProcessTrips(monthData, templates)
    puts "Post-Processing Trips"

    monthData['users']['all'].map {|username, user|
      #puts "User #{username}"
      user['observationData'] ||= []
      #puts "   All Observations: #{user['observationData']}"
      obsDays = user['observationData'].group_by { |obs| obs['dayOfMonth']}
      obsDays.map {|day, obs|

        obs.map {|o|
          zoneId        = templates['locationBySchool'][o['schoolId']]['zoneId']        || ""
          districtId    = templates['locationBySchool'][o['schoolId']]['districtId']    || ""
          monthData['result']['visits']['byDistrict'][districtId]['observations']                   += 1
          monthData['result']['visits']['byDistrict'][districtId]['zones'][zoneId]['observations']  += 1
          monthData['result']['visits']['national']['observations']                                 += 1
        }

        uniqueSchools = obs.uniq! {|o| o['schoolId'] } || []
        monthData['users']['all'][username]['schoolsVisited'] += uniqueSchools.length

        uniqueSchools.map { |school|
          zoneId        = templates['locationBySchool'][school['schoolId']]['zoneId']        || ""
          districtId    = templates['locationBySchool'][school['schoolId']]['districtId']    || ""

          monthData['result']['visits']['byDistrict'][districtId]['visits']                   += 1
          monthData['result']['visits']['byDistrict'][districtId]['zones'][zoneId]['visits']  += 1
          monthData['result']['visits']['national']['visits']                                 += 1
        }
      }
    }

  end

#
#
#  Validate the trip results against the constraints stored in the workflow 
#
#
  def validateTrip(trip, workflow)
    # return valid if validation not enabled for trip
    return true if not workflow['observationValidation']
    return true if not workflow['observationValidation']['enabled']
    return true if not workflow['observationValidation']['constraints']

    #assume incomplete if there is no min and max time defined
    return false if not trip['value']['minTime']
    return false if not trip['value']['maxTime']

    if !@timezone.nil?
      startDate = Time.at(trip['value']['minTime'].to_i / 1000).getlocal(@timezone)
      endDate   = Time.at(trip['value']['maxTime'].to_i / 1000).getlocal(@timezone)
    else 
      startDate = Time.at(trip['value']['minTime'].to_i / 1000)
      endDate   = Time.at(trip['value']['maxTime'].to_i / 1000)
    end

    workflow['observationValidation']['constraints'].each { | type, constraint |
      if type == "timeOfDay"
        startRange = constraint['startTime']['hour']
        endRange   = constraint['endTime']['hour']
        return false if not startDate.hour.between?(startRange, endRange)

      elsif type == "dayOfWeek"
        return false if not constraint['validDays'].include? startDate.wday

      elsif type == "duration"
        if constraint["hours"]
          return false if TimeDifference.between(startDate, endDate).in_hours < constraint["hours"]
        elsif constraint["minutes"]
          return false if TimeDifference.between(startDate, endDate).in_minutes < constraint["minutes"]
        elsif constraint["seconds"]
          return false if TimeDifference.between(startDate, endDate).in_seconds < constraint["seconds"]
        end
      end 
    }

    return true
  end

  def err(display, msg)
    @tripsSkipped = @tripsSkipped + 1
    puts "Trip Skipped: #{msg}" if display
  end

  def getSkippedCount()
    return @tripsSkipped
  end

  def resetSkippedCount()
    @tripsSkipped = 0
  end

end
