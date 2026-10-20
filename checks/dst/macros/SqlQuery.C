// SqlQuery.C -- run one read-only SQL query through ODBC and write the rows as TSV.
//   dsn      ODBC data source name (e.g. daq, FileCatalog)
//   sqlfile  file with a single SELECT / WITH statement (placeholders already filled in)
//   out      output TSV; NULL -> "-", tabs/newlines in values -> space
//   header   1 = first line is the column names
// Anything that is not a single SELECT/WITH statement is refused. On error prints
// "SQL_ERROR <message>" to stderr and exits with code 1 (out is not written).
// the installed odbc++ headers use std::auto_ptr: silence the deprecation warning they trigger
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
#include <odbc++/connection.h>
#include <odbc++/drivermanager.h>
#include <odbc++/resultset.h>
#include <odbc++/resultsetmetadata.h>
#include <odbc++/statement.h>
#include <odbc++/types.h>
#pragma GCC diagnostic pop

#include <TSystem.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>

R__LOAD_LIBRARY(libodbc++.so)

namespace
{
  void fail(const std::string &msg)
  {
    std::cerr << "SQL_ERROR " << msg << std::endl;
    gSystem->Exit(1);
  }

  std::string clean(std::string v)
  {
    std::replace(v.begin(), v.end(), '\t', ' ');
    std::replace(v.begin(), v.end(), '\n', ' ');
    std::replace(v.begin(), v.end(), '\r', ' ');
    return v;
  }
}  // namespace

void SqlQuery(const std::string &dsn, const std::string &sqlfile, const std::string &out, int header = 0)
{
  std::ifstream in(sqlfile);
  if (!in)
  {
    fail("cannot read " + sqlfile);
    return;
  }
  std::stringstream ss;
  ss << in.rdbuf();
  std::string sql = ss.str();

  // read-only guard: one statement, starting with SELECT or WITH
  while (!sql.empty() && (std::isspace(static_cast<unsigned char>(sql.back())) || sql.back() == ';'))
  {
    sql.pop_back();
  }
  size_t b = sql.find_first_not_of(" \t\r\n");
  if (b == std::string::npos)
  {
    fail("empty query in " + sqlfile);
    return;
  }
  sql = sql.substr(b);
  std::string first = sql.substr(0, sql.find_first_of(" \t\r\n("));
  std::transform(first.begin(), first.end(), first.begin(), ::tolower);
  if ((first != "select" && first != "with") || sql.find(';') != std::string::npos)
  {
    fail("refusing anything but a single SELECT/WITH statement: " + sqlfile);
    return;
  }

  std::string tmp = out + ".part";
  try
  {
    std::unique_ptr<odbc::Connection> con(odbc::DriverManager::getConnection(dsn, "", ""));
    std::unique_ptr<odbc::Statement> st(con->createStatement());
    std::unique_ptr<odbc::ResultSet> rs(st->executeQuery(sql));
    odbc::ResultSetMetaData *md = rs->getMetaData();
    int ncol = md->getColumnCount();

    std::ofstream os(tmp);
    if (header)
    {
      for (int i = 1; i <= ncol; ++i)
      {
        os << (i > 1 ? "\t" : "") << clean(md->getColumnName(i));
      }
      os << "\n";
    }
    long nrow = 0;
    while (rs->next())
    {
      for (int i = 1; i <= ncol; ++i)
      {
        std::string v = rs->getString(i);
        if (rs->wasNull() || v.empty())
        {
          v = "-";
        }
        os << (i > 1 ? "\t" : "") << clean(v);
      }
      os << "\n";
      ++nrow;
    }
    os.close();
    std::cout << "SqlQuery: " << dsn << " " << sqlfile << ": " << nrow << " rows" << std::endl;
  }
  catch (odbc::SQLException &e)
  {
    std::remove(tmp.c_str());
    fail(dsn + ": " + std::string(e.getMessage()));
    return;
  }
  std::rename(tmp.c_str(), out.c_str());
}
