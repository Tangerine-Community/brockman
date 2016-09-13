# encoding: utf-8

#require 'rest-client'
#require 'json'
#require_relative "Stash"
require_relative "../utilities/TimeDifference"

class TayariReports

  def initialize( options = {} )

    @couch          = options[:couch]
    @timezone       = options[:timezone]
    @reportSettings = options[:reportSettings]
    #@validation = options[:validation]
    puts "NtpReports: Init Complete"

    @locationList = nil
    @tripsSkipped = 0
    
  end # of initialize

  # Process locations
  def processLocations(templates)
    
    @locationList = @couch.getRequest({ 
      :doc => "location-list", 
      :parseJson => true 
    })

    templates['locationBySchool']                              ||= {}
    templates['locationBySchoolName']                          ||= {}
    templates['locationByZone']                                ||= {}

    # define scope for result
    templates                                                  ||= {}
    templates['result']['visits']                              ||= {}

    templates['result']['visits']['cha']                              ||= {}
    templates['result']['visits']['cha']['byCounty']                  ||= {}
    templates['result']['visits']['cha']['national']                  ||= {}
    templates['result']['visits']['cha']['national']['visits']        ||= 0
    templates['result']['visits']['cha']['national']['quota']         ||= 0

    templates['result']['visits']['dicece']                              ||= {}
    templates['result']['visits']['dicece']['byCounty']                  ||= {}
    templates['result']['visits']['dicece']['national']                  ||= {}
    templates['result']['visits']['dicece']['national']['visits']        ||= 0
    templates['result']['visits']['dicece']['national']['quota']         ||= 0

    # define scope or the geoJSON files
    templates['geoJSON']               ||= {}
    templates['geoJSON']['byCounty']   ||= {}

    #
    # Retrieve Shool Locations and Quotas
    #

    # Init the data structures based on the school list 
    @locationList['locations'].map { | countyId, county |
      templates['result']['visits']['cha']['byCounty'][countyId]                  ||= {}
      templates['result']['visits']['cha']['byCounty'][countyId]['name']          ||= county['label']
      templates['result']['visits']['cha']['byCounty'][countyId]['zones']         ||= {}
      templates['result']['visits']['cha']['byCounty'][countyId]['visits']        ||= 0
      templates['result']['visits']['cha']['byCounty'][countyId]['quota']         ||= 0

      templates['result']['visits']['dicece']['byCounty'][countyId]               ||= {}
      templates['result']['visits']['dicece']['byCounty'][countyId]['name']       ||= county['label']
      templates['result']['visits']['dicece']['byCounty'][countyId]['zones']      ||= {}
      templates['result']['visits']['dicece']['byCounty'][countyId]['visits']     ||= 0
      templates['result']['visits']['dicece']['byCounty'][countyId]['quota']      ||= 0

      #manually flatten out the subCounty data level
      county['children'].map { | subCountyId, subCounty | 
        subCounty['children'].map { | zoneId, zone |

          templates['result']['visits']['cha']['byCounty'][countyId]['zones'][zoneId]                   ||= {}
          templates['result']['visits']['cha']['byCounty'][countyId]['zones'][zoneId]['name']           ||= zone['label']
          templates['result']['visits']['cha']['byCounty'][countyId]['zones'][zoneId]['trips']          ||= []
          templates['result']['visits']['cha']['byCounty'][countyId]['zones'][zoneId]['visits']         ||= 0
          templates['result']['visits']['cha']['byCounty'][countyId]['zones'][zoneId]['quota']          ||= 0

          templates['result']['visits']['dicece']['byCounty'][countyId]['zones'][zoneId]                ||= {}
          templates['result']['visits']['dicece']['byCounty'][countyId]['zones'][zoneId]['name']        ||= zone['label']
          templates['result']['visits']['dicece']['byCounty'][countyId]['zones'][zoneId]['trips']       ||= []
          templates['result']['visits']['dicece']['byCounty'][countyId]['zones'][zoneId]['visits']      ||= 0
          templates['result']['visits']['dicece']['byCounty'][countyId]['zones'][zoneId]['quota']       ||= 0

          templates['result']['visits']['cha']['byCounty'][countyId]['quota']                      += zone['healthQuota'].to_i
          templates['result']['visits']['dicece']['byCounty'][countyId]['quota']                   += zone['educationQuota'].to_i

          templates['result']['visits']['cha']['byCounty'][countyId]['zones'][zoneId]['quota']     += zone['healthQuota'].to_i
          templates['result']['visits']['dicece']['byCounty'][countyId]['zones'][zoneId]['quota']  += zone['educationQuota'].to_i

          templates['result']['visits']['cha']['national']['quota']                                += zone['healthQuota'].to_i
          templates['result']['visits']['dicece']['national']['quota']                             += zone['educationQuota'].to_i

          #init geoJSON Containers
          templates['geoJSON']['byCounty'][countyId]         ||= {}
          templates['geoJSON']['byCounty'][countyId]['data'] ||= []

          templates['locationByZone'][zoneId]                  ||= {}
          templates['locationByZone'][zoneId]['countyId']        = countyId
          templates['locationByZone'][zoneId]['subCountyId']     = subCountyId

          zone['children'].map { | schoolId, school |
            templates['locationBySchool'][schoolId]                  ||= {}
            templates['locationBySchool'][schoolId]['countyId']        = countyId
            templates['locationBySchool'][schoolId]['subCountyId']     = subCountyId
            templates['locationBySchool'][schoolId]['zoneId']          = zoneId

          }
        }
      } 
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
      unless user['doc']['location'].nil?
        location = user['doc']['location']

        #duble each of these up to account for schema change over time - case-sensitive
        county   = location['County'] if !location['County'].nil?
        county   = location['county'] if !location['county'].nil?
        zone     = location['Zone'] if !location['Zone'].nil?
        zone     = location['zone'] if !location['zone'].nil?

        role = user['doc']['role'] || "dicece"

        #verify that the user has a zone and county associated
        if !county.nil? && !zone.nil?
          username                                          = user['doc']['name']
          templates['users']['all']                                      ||= {}
          templates['users']['all'][username]                            ||= {}
          templates['users']['all'][username]['data']                      = user['doc']
          templates['users']['all'][username]['role']                      = role

        end
      end
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

    workflowId = trip['value']['workflowId'] || trip['id']
    username   = trip['value']['user']       || ""

    puts trip['id']

    # handle case of irrelevant workflow 
    return err(true, "Incomplete or Invalid Workflow: #{workflowId}") if not workflows[workflowId]
    #return err(true, "Workflow does not get pre-processed: #{workflowId}") if not workflows[workflowId]['reporting']['preProcess']

    # validate user and role-workflow assocaition
    return err(true, "User does not exist: #{username}") if not templates['users']['all'][username]
    userRole = templates['users']['all'][username]['role']

    #return err(true, "User role does not match with workflow: #{username} | #{templates['users']['all'][username]['role']} - targets #{workflows[workflowId]['reporting']['targetRoles']}") if not workflows[workflowId]['reporting']['targetRoles'].include? userRole

    # validate against the workflow constraints
    validated = validateTrip(trip, workflows[workflowId])
    return err(true, "Trip did not validate against workflow constraints") if not validated

    # verify school
    return err(true, "School was not found in trip") if trip['value']['school'].nil?
          
    schoolId      = trip['value']['school']
    return err(true, "School was not found in database") if templates['locationBySchool'][schoolId].nil?

    
    zoneId        = templates['locationBySchool'][schoolId]['zoneId']        || ""
    subCountyId   = templates['locationBySchool'][schoolId]['subCountyId']   || ""
    countyId      = templates['locationBySchool'][schoolId]['countyId']      || ""
    username      = trip['value']['user'].downcase
    
    #
    # Handle Role-specific calculations
    #
    if userRole == "cha" or userRole == "chews"
      puts "** processing CHA/CHEWS Trip"
      return err(true, "CHA: Missing County") if monthData['result']['visits']['cha']['byCounty'][countyId].nil?
      return err(true, "CHA: Missing Zones")  if monthData['result']['visits']['cha']['byCounty'][countyId]['zones'].nil?
      return err(true, "CHA: Missing Zone")   if monthData['result']['visits']['cha']['byCounty'][countyId]['zones'][zoneId].nil?
      return err(true, "CHA: Missing Visits") if monthData['result']['visits']['cha']['byCounty'][countyId]['zones'][zoneId]['visits'].nil?

      monthData['result']['visits']['cha']['byCounty'][countyId]['zones'][zoneId]['trips'].push "#{trip['id']}"
      
      monthData['result']['visits']['cha']['national']['visits']                                 += 1
      monthData['result']['visits']['cha']['byCounty'][countyId]['visits']                       += 1
      monthData['result']['visits']['cha']['byCounty'][countyId]['zones'][zoneId]['visits']      += 1

      #
      # Process geoJSON data for mapping
      #

      if !trip['value']['gpsData'].nil?
        point = trip['value']['gpsData']

        if !@timezone.nil?
          startDate = Time.at(trip['value']['minTime'].to_i / 1000).getlocal(@timezone)
        else 
          startDate = Time.at(trip['value']['minTime'].to_i / 1000)
        end

        point['role'] = userRole
        point['properties'] = [
          { 'label' => 'Date',            'value' => startDate.strftime("%d-%m-%Y %H:%M") },
          #{ 'label' => 'Activity',        'value' => ''},
          { 'label' => 'Class',           'value' => trip['value']['class'] },
          { 'label' => 'Lesson Week',     'value' => trip['value']['week'] },
          { 'label' => 'Lesson Day',      'value' => trip['value']['day'] },
          { 'label' => 'County',          'value' => titleize(@locationList['locations'][countyId]['label'].downcase) },
          { 'label' => 'Zone',            'value' => titleize(@locationList['locations'][countyId]['children'][subCountyId]['children'][zoneId]['label'].downcase) },
          { 'label' => 'School',          'value' => titleize(@locationList['locations'][countyId]['children'][subCountyId]['children'][zoneId]['children'][schoolId]['label'].downcase) },
          { 'label' => 'CHA',             'value' => titleize(trip['value']['user'].downcase) }
        ]

        monthData['geoJSON']['byCounty'][countyId]['data'].push point
      end

    elsif userRole == "dicece"
      puts "** processing DICECE Trip"
      #skip these steps if either the county or zone are no longer in the primary list 
      return err(true, "DICECE: Missing County") if monthData['result']['visits']['dicece']['byCounty'][countyId].nil?
      return err(true, "DICECE: Missing Zones")  if monthData['result']['visits']['dicece']['byCounty'][countyId]['zones'].nil?
      return err(true, "DICECE: Missing Zone")   if monthData['result']['visits']['dicece']['byCounty'][countyId]['zones'][zoneId].nil?
      return err(true, "DICECE: Missing Visits") if monthData['result']['visits']['dicece']['byCounty'][countyId]['zones'][zoneId]['visits'].nil?

      monthData['result']['visits']['dicece']['byCounty'][countyId]['zones'][zoneId]['trips'].push "#{trip['id']}"
      
      monthData['result']['visits']['dicece']['national']['visits']                                 += 1
      monthData['result']['visits']['dicece']['byCounty'][countyId]['visits']                       += 1
      monthData['result']['visits']['dicece']['byCounty'][countyId]['zones'][zoneId]['visits']      += 1

      #
      # Process geoJSON data for mapping
      #
      if !trip['value']['gpsData'].nil?
        point = trip['value']['gpsData']

        if !@timezone.nil?
          startDate = Time.at(trip['value']['minTime'].to_i / 1000).getlocal(@timezone)
        else 
          startDate = Time.at(trip['value']['minTime'].to_i / 1000)
        end

        point['role'] = userRole
        point['properties'] = [
          { 'label' => 'Date',            'value' => startDate.strftime("%d-%m-%Y %H:%M") },
          #{ 'label' => 'Activity',        'value' => ''},
          { 'label' => 'Class',           'value' => trip['value']['class'] },
          { 'label' => 'Lesson Week',     'value' => trip['value']['week'] },
          { 'label' => 'Lesson Day',      'value' => trip['value']['day'] },
          { 'label' => 'County',          'value' => titleize(@locationList['locations'][countyId]['label'].downcase) },
          { 'label' => 'Zone',            'value' => titleize(@locationList['locations'][countyId]['children'][subCountyId]['children'][zoneId]['label'].downcase) },
          { 'label' => 'School',          'value' => titleize(@locationList['locations'][countyId]['children'][subCountyId]['children'][zoneId]['children'][schoolId]['label'].downcase) },
          { 'label' => 'DICECE',          'value' => titleize(trip['value']['user'].downcase) }
        ]

        monthData['geoJSON']['byCounty'][countyId]['data'].push point
      end

    else 
      return err(false, "Not handling these roles yet: #{userRole}")
    end

  end # of processTrip

#
#
#  Post-Process the trip data
#
#
  def postProcessTrips
    puts "Post-Processing Trips"

   

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
